`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ROM_WINDOWS: every firmware ROM window answers the dump bytes at the address and bank the machine puts them at - the 0xD8000 8 KiB option-ROM window reads BANK3.BIN from offset 0 (EIP = file offset, a verified site), 0xE8000-0xF7FFF reads the fixed lower BIOS (BANK5/BANK6), and 0xF8000-0xFFFFF reads each of the ten selections' own 32 KiB bank (the states 0x043F = 0xE0|bank<<1 and 0x043D install - the port decode itself is tb_pc9821_iobus's) from its first byte to the window's end, and the PC-9801-86's 16 KiB SOUND.ROM window at 0xCC000-0xCFFFF answers the machine-captured dump at all eight of SHADOW.TXT's sampled blocks (FAIL-FIRST: before the window this core answered 0xFF there), bounded above and below by the absent area's 0xFF and swallowing its stores like every other ROM window. The expected bytes are transcribed from bios/xe10/BANK*.BIN and SOUND.ROM - each BANK's first and last dwords, chosen because those pairs are unique across the eight banks - and cross-checked against docs/probes/SHADOW.TXT:150-199, never derived from the RTL. The 0xD8000 gate-off shape (0x053D bit 4 clear) is a recorded DIVERGE row, not a failure: QEMU non-PCI says 0xFF, QEMU's Xa7 class says a DRAM shadow, NP2kai has no gate at all, and the machine has never been read there (the owed probe: read 0xD8000 under 0x53D=0x02).

// ==== WHY ====
// Every ROM must be exposed CORRECTLY.
// The memmap benches pin the TRANSLATION (window -> pack offset); this one pins the
// CONTENT CHAIN end to end through the real pack download and the real responder: the
// bytes a guest reads at each window are the dump's bytes of the bank the machine
// puts there. A wrong window, a bank-select off-by-one (0xE2 landing on bank 2), a
// truncated window or a mis-placed pack slot each make one of these rows read another
// bank's tag and fail by name.
//
// EXPECTED VALUES, NEVER FROM OUR RTL. Each bank is tagged with its own first and last
// dwords (bios/xe10/BANK*.BIN; the pairs are unique across the eight banks - BANK0 and
// BANK3 share their first bytes but not their last, BANK1 and BANK2 the reverse):
//   BANK0  CB9090CB 90CB9090 / C358665B 017C8357   (pack +0x31000)
//   BANK1  0000001B 12750005 / FFFFFFFF FFFFFFFF   (pack +0x39000)
//   BANK2  D88EC88C 0E0FBAFA / FFFFFFFF FFFFFFFF   (pack +0x41000)
//   BANK3  CB9090CB 90CB9090 / FFFFFFFF 2FC6FFFF   (pack +0x70000)
//   BANK4  E9902EEB ABE923D4 / D373FBFB 0000D5B5   (pack +0x00000, the ITF)
//   BANK5  29EB22EB 01200685 / 89065F8D 3BC801F8   (pack +0x10000)
//   BANK6  77186606 F3DE89D5 / 0A083E80 45017502   (pack +0x18000)
//   BANK7  8B066CA1 04A0BADD / 00000000 51B40000   (pack +0x20000)
// and the machine's own capture verifies two rows independently: SHADOW.TXT:149 reads
// F8000:0000 = A1 at the DOS prompt = BANK7.BIN[0] (the bank-7 selection's first byte),
// and SHADOW.TXT:150-199 samples all eight 2 KiB blocks of the 0xCC000 SOUND.ROM window
// and matches bios/xe10/SOUND.ROM at every one:
//   CC000 57561E06 1F165355   CC800 8ADB3300 3A03A785
//   CD000 E80363E8 5E5B0404   CD800 7700063D 0063E812
//   CE000 0000FF02 01010101   CE800 0300033B 0C0E0F00
//   CF000 06B90000 BEDB3300   CF800 C38A0392 C88BE9F6   CFFFC 3C000000
// The pack slots themselves are tools/pack_layout.py's BANK_OFFSET / SOUND_OFFSET; the
// bench writes each bank's tags at its slot, so any bench-table / pack_layout / RTL
// disagreement among the three makes a row read the wrong tag.

// ==== DUT ====
// pc9821_memory_subsystem (the whole responder chain: rom_loader, memory_map,
// window_responder, open_bus) against sdram_backend_model at real sdram.v timing, the
// same shape tb_pc9821_shadow_romsum drives. The pack arrives through the real ioctl
// download path, so the loader's staging is exercised too. top_bank / ide_rom_enable are
// driven directly (the port decode is tb_pc9821_iobus's contract, pinned there).

module tb_pc9821_rom_windows;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // ---- the map's inputs ----
  reg [3:0]  top_bank = 4'd8;            // 8 = the ITF bank, the reset selection
  reg        ide_rom_enable = 1;         // 0x053D bit 4: the option-ROM window's gate
  reg        ide_ram_gate = 1;
  reg        bios_ram_gate = 0;
  reg        top_shadow_en = 0;          // reads stay on the pack: the window's ROM layer
  reg  soft_reboot = 1'b0;   // no reboot strobe in this bench
  reg  [1:0] ems_state = 2'd0;
  reg  [7:0] win0_sel = 8'h08;
  reg [31:0] pack_base = 32'h0000_0000;
  reg [31:0] guest_ram_bytes = 32'h0100_0000;

  // ioctl (the pack download).
  reg         ioctl_download = 0, ioctl_wr = 0;
  reg  [15:0] ioctl_index = 0;
  reg  [26:0] ioctl_addr = 0;
  reg  [15:0] ioctl_dout = 0;
  wire        ioctl_wait, rom_ready, load_error, cpu_run;

  // CPU port.
  reg  [31:0] cpu_addr = 0, cpu_din = 0;
  reg  [3:0]  cpu_be = 4'hF;
  reg  [7:0]  cpu_burstcount = 8'd1;
  reg         cpu_line_read = 0, cpu_valid = 0, cpu_write = 0;
  wire [31:0] cpu_dout;
  wire [31:0] cpu_line_word;
  wire        cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  // Parked ports (GVRAM/TRAM/CG/EGC/scanout/font-reader): not this bench's subject.
  reg         gvram_access_page = 0;
  reg         grcg_we = 0;  reg [7:0] grcg_addr = 0, grcg_din = 0;
  reg         egc_enable = 0;  reg [15:0] egc_access = 0, egc_fgbg = 0, egc_ope = 0,
              egc_fg = 0, egc_mask = 0, egc_bg = 0, egc_sft = 0, egc_leng = 0;
  reg         egc_shift_we = 0;
  reg         scan_enable = 0, scan_line_tick = 0, scan_page = 0;
  reg  [14:0] scan_line_base = 0;
  reg  [6:0]  line_rd_addr = 0;
  reg         line_rd_sel = 0;
  wire [31:0] line_data;
  wire        line_sel, line_ready;
  wire [13:0] tram_addr;  wire [7:0] tram_din;  wire tram_we;
  wire [4:0]  cg_win_byte_sel;  wire cg_win_rd;  wire [7:0] cg_win_din;
  wire [17:0] font_addr;  wire [15:0] font_data;  wire font_we;
  reg  [18:0] font_req_addr = 0;  reg font_req = 0;
  wire        font_word_valid;  wire [31:0] font_word_data;
  wire [31:0] fmem_addr, fmem_din;  wire fmem_valid, fmem_write;
  wire  [3:0] fmem_be;  wire [7:0] fmem_burstcount;
  reg         fmem_ready = 0, fmem_resp_valid = 0;
  reg  [31:0] fmem_dout = 0;

  // The memory backend.
  wire [31:0] mem_addr, mem_din, mem_din_hi, mem_dout;
  wire        mem_gath;
  wire [440:0] mem_gath_extra;
  wire  [3:0] mem_be;
  wire  [7:0] mem_burstcount;
  wire        mem_valid, mem_write;
  wire        mem_ready, mem_resp_valid;
  wire        mem_busy;
  wire [31:0] mem_accepts, mem_beats;

  // ==== DUT ====
  // The 16-colour select (port 0x6A FF2 num 0): 0 = the digital mode the machine resets to,
  // where 0xE0000-0xE7FFF is open bus (pc9821_memory_map e_plane_nc).
  reg        mode2_16color = 1'b0;
  pc9821_memory_subsystem #(.SYS_CLOCK_HZ(100_000_000)) dut (
      .mode2_16color(mode2_16color),
      .scan_dot_ce(1'b0), .scan_dot_act(1'b1),
      .clk(clk), .reset(reset), .top_bank(top_bank),
      .ems_state(ems_state), .ide_rom_enable(ide_rom_enable), .d8_bank(2'b00), .ide_ram_gate(ide_ram_gate),
      .bios_ram_gate(bios_ram_gate), .top_shadow_en(top_shadow_en), .soft_reboot(soft_reboot),
      .win0_sel(win0_sel), .win0_sel_moved(win0_sel != 8'h08), .sys16m_en(1'b0),
      .pack_base(pack_base), .guest_ram_bytes(guest_ram_bytes),
      .gvram_access_page(gvram_access_page),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din),
      .egc_enable(egc_enable), .egc_access(egc_access), .egc_fgbg(egc_fgbg),
      .egc_ope(egc_ope), .egc_fg(egc_fg), .egc_mask(egc_mask), .egc_bg(egc_bg),
      .egc_sft(egc_sft), .egc_leng(egc_leng), .egc_shift_we(egc_shift_we),
      .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
      .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
      .ioctl_wait(ioctl_wait), .rom_ready(rom_ready), .load_error(load_error),
      .cpu_run(cpu_run),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .scan_line_base(scan_line_base),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready),
      .font_addr(font_addr), .font_data(font_data), .font_we(font_we),
      .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_dout(cpu_dout),
      .cpu_be(cpu_be),
      .cpu_burstcount(cpu_burstcount), .cpu_line_read(cpu_line_read),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write), .cpu_ready(cpu_ready),
      .cpu_resp_valid(cpu_resp_valid), .tram_addr(tram_addr), .tram_din(tram_din), .tram_we(tram_we),
      .tram_dout(8'h00),
      .cg_win_byte_sel(cg_win_byte_sel), .cg_win_rd(cg_win_rd),
      .cg_win_dout(8'h00), .cg_win_din(cg_win_din), .cg_win_we(),
      .font_req_addr(font_req_addr), .font_req(font_req),
      .font_word_valid(font_word_valid), .font_word_data(font_word_data),
      .fmem_addr(fmem_addr), .fmem_din(fmem_din), .fmem_valid(fmem_valid),
      .fmem_write(fmem_write), .fmem_be(fmem_be),
      .fmem_burstcount(fmem_burstcount), .fmem_ready(fmem_ready),
      .fmem_dout(fmem_dout), .fmem_resp_valid(fmem_resp_valid),
      .mem_addr(mem_addr), .mem_din(mem_din), .mem_din_hi(mem_din_hi), .mem_gath(mem_gath), .mem_gath_extra(mem_gath_extra), .sdram_size(2'd2),
      .mem_dout(mem_dout),
      .mem_be(mem_be),
      .mem_burstcount(mem_burstcount), .mem_valid(mem_valid), .mem_write(mem_write), .mem_ready(mem_ready),
      .mem_resp_valid(mem_resp_valid)
  );

  sdram_backend_model #(
      .ACCEPT_TO_RESP(5), .WRITE_BUSY(3), .LINE_RESP(0), .WORDS_LOG2(20)
  ) backend (
      .clk(clk), .reset(reset), .valid(mem_valid), .ready(mem_ready),
      .write(mem_write), .addr(mem_addr), .din(mem_din), .din_hi(mem_din_hi), .be(mem_be), .gath(mem_gath), .gath_extra(mem_gath_extra),
      .burstcount(mem_burstcount), .dout(mem_dout), .resp_valid(mem_resp_valid),
      .busy(mem_busy), .accepts(mem_accepts), .beats(mem_beats)
  );

  integer errors = 0;

  // ==== CHECKS ====

  // ---- stimulus helpers (the shadow_romsum shapes) ----
  task automatic send_word(input [26:0] addr, input [15:0] data);
    begin
      while (ioctl_wait) @(negedge clk);
      @(negedge clk);
      ioctl_addr = addr;
      ioctl_dout = data;
      ioctl_wr = 1;
      @(negedge clk);
      ioctl_wr = 0;
    end
  endtask

  // One dword of the synthetic pack: little-endian bytes b0..b3 at a dword-aligned
  // pack offset (the loader stages words, so two words per dword).
  task automatic place_dword(input [26:0] addr, input [31:0] value);
    begin
      send_word(addr, value[15:0]);
      send_word(addr + 27'd2, value[31:16]);
    end
  endtask

  // One CPU dword read through the responder chain, bounded so a wedged route fails
  // by name rather than by runner timeout. THE PROTOCOL SHAPE: cpu_valid is dropped at
  // the ACCEPT (the cycle after cpu_ready is seen), not at the response - holding it
  // past the response re-accepts the same request when the backend returns to idle,
  // and the extra response beat then collides with the next row's responder and trips
  // the subsystem's route-overlap assertion (measured: hit exactly once, at the first
  // open-route row after a map-route row).
  task automatic cpu_read(input [31:0] a, output [31:0] d);
    integer g;
    begin
      @(negedge clk);
      cpu_addr = a; cpu_din = 32'd0; cpu_be = 4'hF;
      cpu_write = 0; cpu_line_read = 0; cpu_valid = 1;
      g = 0; while (!cpu_ready && g < 400) begin @(negedge clk); g = g + 1; end
      if (!cpu_ready) $fatal(1, "TB_PC9821_ROM_WINDOWS: no ready for read %08x", a);
      @(negedge clk); cpu_valid = 0;
      g = 0; while (!cpu_resp_valid && g < 400) begin @(negedge clk); g = g + 1; end
      if (!cpu_resp_valid) $fatal(1, "TB_PC9821_ROM_WINDOWS: no response for read %08x", a);
      d = cpu_dout;
      repeat (4) @(negedge clk);
    end
  endtask

  task automatic cpu_write_byte(input [31:0] a, input [7:0] v);
    integer g;
    begin
      @(negedge clk);
      cpu_addr = a; cpu_din = {24'd0, v}; cpu_be = 4'h1;
      cpu_write = 1; cpu_line_read = 0; cpu_valid = 1;
      g = 0; while (!cpu_ready && g < 400) begin @(negedge clk); g = g + 1; end
      if (!cpu_ready) $fatal(1, "TB_PC9821_ROM_WINDOWS: no ready for write %08x", a);
      @(negedge clk); cpu_valid = 0;
      repeat (4) @(negedge clk);
    end
  endtask

  reg [31:0] rd;

  // The row: the window address must answer the dump's dword.
  task automatic check_dword(input [31:0] a, input [31:0] want,
                             input [8*48-1:0] name, input [8*80-1:0] cited);
    begin
      cpu_read(a, rd);
      if (rd !== want) begin
        $display("FAIL     %0s: %08x = %08x, want %08x   [%0s]", name, a, rd, want, cited);
        errors = errors + 1;
      end else begin
        $display("ok       %0s: %08x = %08x   [%0s]", name, a, rd, cited);
      end
    end
  endtask

  initial begin
    // ---- COLD BOOT: stage the synthetic pack through the real loader ----
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    ioctl_index = 16'd0;
    ioctl_download = 1;
    @(negedge clk);

    // Bank tags at each bank's pack slot (tools/pack_layout.py BANK_OFFSET); first
    // dwords at the slot base, last dwords at slot+0x7FF8 (the window's top).
    place_dword(27'h000_3_1000, 32'hCB9090CB); place_dword(27'h000_3_1004, 32'h90CB9090);   // BANK0 first
    place_dword(27'h000_3_8FF8, 32'hC358665B); place_dword(27'h000_3_8FFC, 32'h017C8357);   // BANK0 last
    place_dword(27'h000_3_9000, 32'h0000001B); place_dword(27'h000_3_9004, 32'h12750005);   // BANK1 first
    place_dword(27'h000_4_0FF8, 32'hFFFFFFFF); place_dword(27'h000_4_0FFC, 32'hFFFFFFFF);   // BANK1 last
    place_dword(27'h000_4_1000, 32'hD88EC88C); place_dword(27'h000_4_1004, 32'h0E0FBAFA);   // BANK2 first
    place_dword(27'h000_4_8FF8, 32'hFFFFFFFF); place_dword(27'h000_4_8FFC, 32'hFFFFFFFF);   // BANK2 last
    place_dword(27'h000_7_0000, 32'hCB9090CB); place_dword(27'h000_7_0004, 32'h90CB9090);   // BANK3 first
    place_dword(27'h000_7_1FF8, 32'h01000809); place_dword(27'h000_7_1FFC, 32'hE33DFF00);   // BANK3 file 0x1FF8: the 8 KiB option window's end
    place_dword(27'h000_7_7FF8, 32'hFFFFFFFF); place_dword(27'h000_7_7FFC, 32'h2FC6FFFF);   // BANK3 last
    place_dword(27'h000_0_0000, 32'hE9902EEB); place_dword(27'h000_0_0004, 32'hABE923D4);   // BANK4 first (ITF)
    place_dword(27'h000_0_7FF8, 32'hD373FBFB); place_dword(27'h000_0_7FFC, 32'h0000D5B5);   // BANK4 last
    place_dword(27'h000_1_0000, 32'h29EB22EB); place_dword(27'h000_1_0004, 32'h01200685);   // BANK5 first
    place_dword(27'h000_1_7FF8, 32'h89065F8D); place_dword(27'h000_1_7FFC, 32'h3BC801F8);   // BANK5 last
    place_dword(27'h000_1_8000, 32'h77186606); place_dword(27'h000_1_8004, 32'hF3DE89D5);   // BANK6 first
    place_dword(27'h000_1_FFF8, 32'h0A083E80); place_dword(27'h000_1_FFFC, 32'h45017502);   // BANK6 last
    place_dword(27'h000_2_0000, 32'h8B066CA1); place_dword(27'h000_2_0004, 32'h04A0BADD);   // BANK7 first
    place_dword(27'h000_2_7FF8, 32'h00000000); place_dword(27'h000_2_7FFC, 32'h51B40000);   // BANK7 last

    // The PC-9801-86 SOUND.ROM window's eight machine-captured blocks at
    // SOUND_OFFSET + 2 KiB*k (tools/pack_layout.py SOUND_OFFSET), and its end dword.
    place_dword(27'h000C_6800, 32'h57561E06); place_dword(27'h000C_6804, 32'h1F165355);
    place_dword(27'h000C_7000, 32'h8ADB3300); place_dword(27'h000C_7004, 32'h3A03A785);
    place_dword(27'h000C_7800, 32'hE80363E8); place_dword(27'h000C_7804, 32'h5E5B0404);
    place_dword(27'h000C_8000, 32'h7700063D); place_dword(27'h000C_8004, 32'h0063E812);
    place_dword(27'h000C_8800, 32'h0000FF02); place_dword(27'h000C_8804, 32'h01010101);
    place_dword(27'h000C_9000, 32'h0300033B); place_dword(27'h000C_9004, 32'h0C0E0F00);
    place_dword(27'h000C_9800, 32'h06B90000); place_dword(27'h000C_9804, 32'hBEDB3300);
    place_dword(27'h000C_A000, 32'hC38A0392); place_dword(27'h000C_A004, 32'hC88BE9F6);
    place_dword(27'h000C_A7FC, 32'h3C000000);

    ioctl_download = 0;
    repeat (12) @(posedge clk);
    if (!rom_ready || load_error)
      $fatal(1, "TB_PC9821_ROM_WINDOWS: pack did not publish ready (ready=%b err=%b)",
             rom_ready, load_error);

    // ---- 1. The 0xD8000 option-ROM window: 8 KiB of BANK3 from offset 0 ----
    // The freeze lane's verified site: CS=D800, EIP = BANK3.BIN file offset.
    ide_rom_enable = 1;
    check_dword(32'h000D_8000, 32'hCB9090CB, "D8000 IDE ROM first",
                "bios/xe10/BANK3.BIN[0]; emm386-freeze3-REPORT.md 2");
    check_dword(32'h000D_8004, 32'h90CB9090, "D8000 IDE ROM first+4",
                "bios/xe10/BANK3.BIN[4]");
    check_dword(32'h000D_9FFC, 32'hE33DFF00, "D9FFC IDE ROM window end (8 KiB)",
                "bios/xe10/BANK3.BIN[0x1FFC]; QEMU ide_rom 0x2000");

    // ---- 2. The lower BIOS: the fixed 64 KiB at 0xE8000-0xF7FFF (BANK5/BANK6) ----
    check_dword(32'h000E_8000, 32'h29EB22EB, "E8000 lower BIOS (bank 5)",
                "bios/xe10/BANK5.BIN[0] = BIOS.ROM[0]");
    check_dword(32'h000E_8004, 32'h01200685, "E8000 lower BIOS first+4",
                "bios/xe10/BANK5.BIN[4]");
    check_dword(32'h000F_0000, 32'h77186606, "F0000 lower BIOS (bank 6)",
                "bios/xe10/BANK6.BIN[0] = BIOS.ROM[0x8000]");
    check_dword(32'h000F_0004, 32'hF3DE89D5, "F0000 lower BIOS first+4",
                "bios/xe10/BANK6.BIN[4]");
    check_dword(32'h000F_7FFC, 32'h45017502, "F7FFC lower BIOS end",
                "bios/xe10/BANK6.BIN[0x7FFC]");

    // ---- 3. The 0xF8000 window: every selection's own 32 KiB bank ----
    // Selection 8 = the ITF state (0x043D = 0x00/0x10/0x18; the reset state), 9 = the
    // BIOS top (0x043D = 0x02/0x12), 0..7 = 0x043F = 0xE0|bank<<1.
    top_bank = 4'd8;
    check_dword(32'h000F_8000, 32'hE9902EEB, "bank 8 (ITF, 0x043D) first",
                "bios/xe10/BANK4.BIN[0] = the ITF");
    check_dword(32'h000F_8004, 32'hABE923D4, "bank 8 (ITF) first+4",
                "bios/xe10/BANK4.BIN[4]");
    check_dword(32'h000F_FFF8, 32'hD373FBFB, "bank 8 (ITF) last",
                "bios/xe10/BANK4.BIN[0x7FF8]");
    check_dword(32'h000F_FFFC, 32'h0000D5B5, "bank 8 (ITF) window end",
                "bios/xe10/BANK4.BIN[0x7FFC]");
    top_bank = 4'd4;
    check_dword(32'h000F_8000, 32'hE9902EEB, "bank 4 (0x043F=0xE8) = the ITF image",
                "bios/xe10/BANK4.BIN[0]; FW BANK3@0x209B writes 0xE8 to reach it");
    top_bank = 4'd9;
    check_dword(32'h000F_8000, 32'h8B066CA1, "bank 9 (BIOS top, 0x043D) first",
                "bios/xe10/BANK7.BIN[0] = A1, also SHADOW.TXT:149");
    check_dword(32'h000F_8004, 32'h04A0BADD, "bank 9 (BIOS top) first+4",
                "bios/xe10/BANK7.BIN[4]");
    top_bank = 4'd7;
    check_dword(32'h000F_8000, 32'h8B066CA1, "bank 7 (0x043F=0xEE) = the BIOS top",
                "bios/xe10/BANK7.BIN[0]; emm386-freeze3-REPORT.md 2");
    check_dword(32'h000F_FFF8, 32'h00000000, "bank 7 (BIOS top) last",
                "bios/xe10/BANK7.BIN[0x7FF8]");
    check_dword(32'h000F_FFFC, 32'h51B40000, "bank 7 (BIOS top) window end",
                "bios/xe10/BANK7.BIN[0x7FFC]");
    top_bank = 4'd0;
    check_dword(32'h000F_8000, 32'hCB9090CB, "bank 0 (0x043F=0xE0) first",
                "bios/xe10/BANK0.BIN[0]");
    check_dword(32'h000F_FFF8, 32'hC358665B, "bank 0 last",
                "bios/xe10/BANK0.BIN[0x7FF8] - not BANK3's (their first bytes agree)");
    top_bank = 4'd1;
    check_dword(32'h000F_8000, 32'h0000001B, "bank 1 (0x043F=0xE2) first",
                "bios/xe10/BANK1.BIN[0]; FW BANK6@0x5308 writes 0xE2 and copies it");
    check_dword(32'h000F_FFF8, 32'hFFFFFFFF, "bank 1 last",
                "bios/xe10/BANK1.BIN[0x7FF8] - not BANK2's (their last bytes agree)");
    top_bank = 4'd2;
    check_dword(32'h000F_8000, 32'hD88EC88C, "bank 2 (0x043F=0xE4) first",
                "bios/xe10/BANK2.BIN[0]");
    check_dword(32'h000F_FFFC, 32'hFFFFFFFF, "bank 2 window end",
                "bios/xe10/BANK2.BIN[0x7FFC]");
    top_bank = 4'd3;
    check_dword(32'h000F_8000, 32'hCB9090CB, "bank 3 (0x043F=0xE6) first",
                "bios/xe10/BANK3.BIN[0]; FW BANK4@0x253E writes 0xE6 and calls FA00:0000");
    check_dword(32'h000F_FFF8, 32'hFFFFFFFF, "bank 3 last",
                "bios/xe10/BANK3.BIN[0x1FF8] - not BANK0's");
    top_bank = 4'd5;
    check_dword(32'h000F_8000, 32'h29EB22EB, "bank 5 (0x043F=0xEA) first",
                "bios/xe10/BANK5.BIN[0] = the same bytes 0xE8000 shows");
    top_bank = 4'd6;
    check_dword(32'h000F_8000, 32'h77186606, "bank 6 (0x043F=0xEC) first",
                "bios/xe10/BANK6.BIN[0] = the same bytes 0xF0000 shows");
    check_dword(32'h000F_FFFC, 32'h45017502, "bank 6 window end",
                "bios/xe10/BANK6.BIN[0x7FFC]");

    // ---- 4. The top-of-4G alias of the window ----
    top_bank = 4'd8;
    check_dword(32'hFFFF_8000, 32'hE9902EEB, "FFFF8000 alias = bank 8 (ITF) first",
                "QEMU top_mirror over lowmem[0xA0000..0x100000]");
    check_dword(32'hFFFF_8004, 32'hABE923D4, "FFFF8000 alias first+4",
                "bios/xe10/BANK4.BIN[4]");

    // ---- 5. The PC-9801-86 SOUND.ROM window: 16 KiB at 0xCC000 ----
    // FAIL-FIRST: before the window this core answered 0xFF over the whole C-bus area,
    // so every row below read FFFFFFFF and failed.
    check_dword(32'h000C_C000, 32'h57561E06, "CC000 SOUND.ROM block 0",
                "SHADOW.TXT:150 +C000 row = bios/xe10/SOUND.ROM[0]");
    check_dword(32'h000C_C004, 32'h1F165355, "CC000 SOUND.ROM block 0 +4",
                "SHADOW.TXT:150 +C000 row = bios/xe10/SOUND.ROM[4]");
    check_dword(32'h000C_C800, 32'h8ADB3300, "CC800 SOUND.ROM block 1",
                "SHADOW.TXT +C800 row = SOUND.ROM[0x800]");
    check_dword(32'h000C_D000, 32'hE80363E8, "CD000 SOUND.ROM block 2",
                "SHADOW.TXT +D000 row = SOUND.ROM[0x1000]");
    check_dword(32'h000C_D800, 32'h7700063D, "CD800 SOUND.ROM block 3",
                "SHADOW.TXT +D800 row = SOUND.ROM[0x1800]");
    check_dword(32'h000C_E000, 32'h0000FF02, "CE000 SOUND.ROM block 4",
                "SHADOW.TXT +E000 row = SOUND.ROM[0x2000]");
    check_dword(32'h000C_E800, 32'h0300033B, "CE800 SOUND.ROM block 5",
                "SHADOW.TXT +E800 row = SOUND.ROM[0x2800]");
    check_dword(32'h000C_F000, 32'h06B90000, "CF000 SOUND.ROM block 6",
                "SHADOW.TXT +F000 row = SOUND.ROM[0x3000]");
    check_dword(32'h000C_F800, 32'hC38A0392, "CF800 SOUND.ROM block 7",
                "SHADOW.TXT +F800 row = SOUND.ROM[0x3800]");
    check_dword(32'h000C_FFFC, 32'h3C000000, "CFFFC SOUND.ROM window end (16 KiB)",
                "bios/xe10/SOUND.ROM[0x3FFC]");
    // The window's exact extent: the absent area owns both neighbours (0xFF, the
    // machine's own ffblocks=0028 rows), so a window one block wide in either
    // direction fails here.
    check_dword(32'h000C_BFFC, 32'hFFFFFFFF, "CBFFC still the absent area",
                "SHADOW.TXT REGION C0000..D7FFF ffblocks=0028");
    check_dword(32'h000D_0000, 32'hFFFFFFFF, "D0000 still the absent area",
                "SHADOW.TXT REGION C0000..D7FFF ffblocks=0028");

    // The window is READ-ONLY like every ROM window (NP2kai drops the store: its
    // memd000_wr8 gates writes on the ROM-loaded pages, cpumem.c:135 memnc_wr8 is the
    // shape): a store is swallowed and the pack's byte survives.
    cpu_write_byte(32'h000C_C000, 8'h5A);
    check_dword(32'h000C_C000, 32'h57561E06, "CC000 after a guest store (dropped)",
                "the ROM pack is read-only");
    if (backend.peek(32'h000C_6800) !== 32'h57561E06) begin
      $display("FAIL     the SOUND.ROM store reached the pack: pack[0xC6800]=%08x, want 57561E06",
               backend.peek(32'h000C_6800));
      errors = errors + 1;
    end

    // ---- 6. DIVERGE (recorded, not failed): 0xD8000 with the 0x053D bit-4 gate CLEAR ----
    // The shape is UNMEASURED on the machine and the three references split three ways
    // (QEMU non-PCI rom_empty = 0xFF, QEMU's Xa7 class = a DRAM shadow, NP2kai has no
    // 0x053D at all and keeps the ROM visible). The owed probe: read 0xD8000 under
    // 0x53D = 0x02 on the machine. Until it lands this row RECORDS the answer rather
    // than pinning one.
    ide_rom_enable = 0;
    cpu_read(32'h000D_8000, rd);
    $display("DIVERGE  D8000 gate-off (0x053D bit 4 clear) reads %08x; MEAS capture-pending (probe: read 0xD8000 under 0x53D=0x02)   [QEMU non-PCI FF / Xa7 RAM / NP2kai ROM]", rd);
    ide_rom_enable = 1;

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_ROM_WINDOWS: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_ROM_WINDOWS: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog, so a hang is a named failure rather than a runner timeout.
  initial begin
    #4_000_000;
    $fatal(1, "TB_PC9821_ROM_WINDOWS: FAIL (watchdog: the bench did not finish)");
  end

endmodule
