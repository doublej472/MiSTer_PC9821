`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PEGVRAM:
// With the 15-16 MiB system-space hole on (port 0x043B bit 2 cleared, as the ITF's phase-2 test requests with `out 0x43B,0`) the PEGC's 512 KiB extended VRAM exists at physical 0xF00000-0xF7FFFF: a 512 KiB fill of 0xFFFFFFFF completes and reads back, then a fill of 0 reads back, at real sdram.v timing, through the ordinary mapper route; and the same window with the hole OFF is ordinary RAM that leaves no trace in the PEGC store. The aperture is gated by the register file's [0xE0102] bit 0 (NP2kai memvgaf_rd8/wr8; MAME pegc_vram_view): with it clear a read answers 0xFF and a store leaves no trace (FAIL-FIRST row: before the gate landed the store reached the backend), and the machine's own enable flow - open the PEGC view, write [0xE0102]=1 through the register file - turns it on. The two packed windows (0xA8000 with bank 0xE0004, 0xB0000 with bank 0xE0006) reach the SAME store at {bank, offset[14:0]} (NP2kai memvga.c VGARD8/VGAWR8, qemu (bank & 0x0f) * 0x8000) and round-trip against the flat aperture, up to the store's top - banks 14 and 15, where the 640x480 frame at the Win95 driver's 1024-byte pitch ends (line 479 at 0x77C00) - and against the 0xFFF00000 alias (NP2kai i386c/cpumem.c memp_read8 -> memvgaf) in both directions. The ITF's own phase-2 block fills and verifies exactly this range at 0xF00000 after clearing 0x043B bit 2 and setting [0xE0102]=1, and its failure prints the warn-only "EXTENDED GVRAM ERROR". The size and the address are qemu-pc98's (PEGC_POST_SIZE = 0x80000 decoded at 0xf00000, hw/display/pc98-vga.c pegc_post_readb/writeb) and NP2kai's (memvgaf over vramex[0x80000], mem/memvga.c), both 512 KiB flat RAMs.

// ==== DUT ====
// pc9821_memory_subsystem with its backend answered by sdram_backend_model at the timing
// sdram.v documents (ACCEPT_TO_RESP=5, WRITE_BUSY=3). The window is driven only through the
// 0x043B latch the iobus owns (sys16m_en here), so the bench exercises the same decode the
// card does; the storage is read back both through the CPU route and with backend.peek.

module tb_pc9821_pegvram;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // The memory-map function inputs. pack_base == guest_ram_bytes is the real wiring, so the
  // PEGC base the subsystem computes (pack_base + PACK_BYTES + 0x80000) is the shipped one.
  reg [3:0]  top_bank = 4'd8;
  reg        ide_rom_enable = 0;
  reg        bios_ram_gate = 0;
  reg  [1:0] ems_state = 2'd0;
  reg [7:0]  win0_sel = 8'h08;
  reg [31:0] pack_base = 32'h0100_0000;
  reg [31:0] guest_ram_bytes = 32'h0100_0000;
  // 0x043B bit 2's latch. 1 is the hole ON, which is what the ITF's phase-2 test selects.
  reg        sys16m_en = 1'b1;
  // The PEGC view select (pc9821_crtc's mode2_256col): the register file's
  // [0xE0102] aperture enable lives behind it (the machine's own flow).
  reg        pegc_256 = 1'b0;
  wire       top_shadow_en;

  // pc9821_memory_subsystem computes pack_base + PACK_BYTES (0x100000) + 0x80000.
  localparam [31:0] PEG_BASE  = 32'h0118_0000;
  localparam integer FILL_DWORDS = 131072;   // 512 KiB, the ITF's own a32 rep stosd count

  // ioctl (the pack download: one word is enough to publish rom_ready).
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

  // Parked ports (GVRAM/TRAM/CG/EGC/scanout/font reader): not this bench's subject.
  reg         gvram_access_page = 0;
  reg         grcg_we = 0;  reg [7:0] grcg_addr = 0, grcg_din = 0;
  reg         egc_enable = 0;
  reg [15:0]  egc_access = 0, egc_fgbg = 0, egc_ope = 0, egc_fg = 0,
              egc_mask = 0, egc_bg = 0, egc_sft = 0, egc_leng = 0;
  reg         egc_shift_we = 0;
  reg         scan_enable = 0, scan_line_tick = 0, scan_page = 0;
  reg         scan_walk_page = 0;
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

  // The memory backend, at real sdram.v timing. WORDS_LOG2=23 (32 MiB of storage) so the
  // PEGC base at 0x1180000 lands on its own words instead of aliasing the low ones.
  wire [31:0] mem_addr, mem_din, mem_din_hi, mem_dout;
  // The G3 gather session's qualifier and entries (pc9821_memory_subsystem's
  // mem_gath* outputs, carried into the model so a grouped drain applies all its entries).
  wire        mem_gath;
  wire [440:0] mem_gath_extra;
  wire  [3:0] mem_be;
  wire  [7:0] mem_burstcount;
  wire        mem_valid, mem_write;
  wire        mem_ready, mem_resp_valid;
  wire        mem_busy;
  wire [31:0] mem_accepts, mem_beats;

  pc9821_memory_subsystem #(.SYS_CLOCK_HZ(100_000_000)) dut (
      .scan_dot_ce(1'b0), .scan_dot_act(1'b1),
      .clk(clk), .reset(reset), .top_bank(top_bank),
      .ems_state(ems_state), .ide_rom_enable(ide_rom_enable), .d8_bank(2'b00), .ide_ram_gate(1'b1),
      .bios_ram_gate(bios_ram_gate), .top_shadow_en(top_shadow_en),
      .win0_sel(win0_sel), .win0_sel_moved(win0_sel != 8'h08), .sys16m_en(sys16m_en),
      .pegc_256(pegc_256),
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
      .scan_page(scan_page), .scan_walk_page(scan_walk_page),
      .scan_line_base(scan_line_base),
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
      .ACCEPT_TO_RESP(5), .WRITE_BUSY(3), .LINE_RESP(0), .WORDS_LOG2(23)
  ) backend (
      .clk(clk), .reset(reset), .valid(mem_valid), .ready(mem_ready),
      .write(mem_write), .addr(mem_addr), .din(mem_din), .din_hi(mem_din_hi), .be(mem_be), .gath(mem_gath), .gath_extra(mem_gath_extra),
      .burstcount(mem_burstcount), .dout(mem_dout), .resp_valid(mem_resp_valid),
      .busy(mem_busy), .accepts(mem_accepts), .beats(mem_beats)
  );

  integer errors = 0;

  // ==== STIMULUS ====
  // A hard watchdog so a route that stops answering is a FAIL, not a stall.
  initial begin
    #300_000_000;
    $fatal(1, "TB_PC9821_PEGVRAM: FAIL watchdog (the fill/verify did not finish)");
  end

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

  // One CPU store through the mapper. A write completes at the ACCEPT (z486 memory.sv
  // normal_req_complete), so the bound is ready, not resp_valid.
  task automatic cpu_store(input [31:0] a, input [31:0] d, input [3:0] be);
    integer g;
    begin
      @(negedge clk);
      cpu_addr = a; cpu_din = d; cpu_be = be; cpu_write = 1; cpu_line_read = 0;
      cpu_burstcount = 8'd1; cpu_valid = 1;
      g = 0; while (!cpu_ready && g < 400) begin @(negedge clk); g = g + 1; end
      if (!cpu_ready) $fatal(1, "TB_PC9821_PEGVRAM: no ready for write %08x", a);
      @(negedge clk); cpu_valid = 0;
    end
  endtask

  // One CPU load. A read completes on the backend's response.
  task automatic cpu_load(input [31:0] a, output [31:0] d);
    integer g;
    begin
      @(negedge clk);
      cpu_addr = a; cpu_din = 32'd0; cpu_be = 4'hF; cpu_write = 0; cpu_line_read = 0;
      cpu_burstcount = 8'd1; cpu_valid = 1;
      g = 0; while (!cpu_ready && g < 400) begin @(negedge clk); g = g + 1; end
      if (!cpu_ready) $fatal(1, "TB_PC9821_PEGVRAM: no ready for read %08x", a);
      g = 0; while (!cpu_resp_valid && g < 400) begin @(negedge clk); g = g + 1; end
      if (!cpu_resp_valid) $fatal(1, "TB_PC9821_PEGVRAM: no response for read %08x", a);
      d = cpu_dout;
      @(negedge clk); cpu_valid = 0;
    end
  endtask

  reg [31:0] rd;
  integer i, bad;

  // The ITF's phase-2 fill/verify over the whole 512 KiB: fill `pattern`, read every dword
  // back and require it. Returns the number of mismatches in `bad`.
  task automatic fill_verify(input [31:0] pattern, input integer phase);
    begin
      for (i = 0; i < FILL_DWORDS; i = i + 1)
        cpu_store(32'h00F0_0000 + (i << 2), pattern, 4'hF);
      bad = 0;
      for (i = 0; i < FILL_DWORDS; i = i + 1) begin
        cpu_load(32'h00F0_0000 + (i << 2), rd);
        if (rd !== pattern) begin
          if (bad < 4)
            $display("FAIL phase %0d: 0x%06x read %08x, want %08x",
                     phase, 32'h00F0_0000 + (i << 2), rd, pattern);
          bad = bad + 1;
        end
      end
      if (bad != 0) begin
        $display("FAIL phase %0d: %0d of %0d dwords wrong after the 0x%08x fill",
                 phase, bad, FILL_DWORDS, pattern);
        errors = errors + 1;
      end else
        $display("  phase %0d: 512 KiB at 0xF00000 filled with 0x%08x and read back", phase, pattern);
    end
  endtask

  // ==== CHECKS ====
  initial begin
    // ---- reset and pack download, exactly as the other subsystem benches do. ----
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    ioctl_index = 16'd0;
    ioctl_download = 1;
    @(negedge clk);
    send_word(27'd0, 16'h1234);
    ioctl_download = 0;
    repeat (12) @(posedge clk);
    if (!rom_ready || load_error || !cpu_run)
      $fatal(1, "TB_PC9821_PEGVRAM: pack did not publish ready (ready=%b err=%b run=%b)",
             rom_ready, load_error, cpu_run);
    if (PEG_BASE !== 32'h0118_0000)
      $fatal(1, "TB_PC9821_PEGVRAM: PEG base drifted to %08x", PEG_BASE);

    // ---- CHK-0: the 0xE0102 aperture gate (NP2kai memvgaf_rd8/wr8; MAME
    // pegc_vram_view). With the register file's VRAM enable clear - its reset
    // value - a read answers open bus 0xFF and a store leaves no trace in the
    // PEGC store. FAIL-FIRST: before the gate landed the store reached the
    // backend here and this check names it. ----
    cpu_store(32'h00F0_0000, 32'hDEAD_BEEF, 4'hF);
    if (backend.peek(PEG_BASE + 32'h0000_0000) !== 32'h0000_0000) begin
      $display("FAIL CHK-0: a store to 0xF00000 with [0xE0102] clear landed in the PEGC store (%08x)",
               backend.peek(PEG_BASE));
      errors = errors + 1;
    end
    cpu_load(32'h00F0_0000, rd);
    if (rd !== 32'hFFFF_FFFF) begin
      $display("FAIL CHK-0: 0xF00000 with [0xE0102] clear read %08x, want FFFFFFFF (memvgaf_rd8 answers 0xFF)",
               rd);
      errors = errors + 1;
    end

    // The machine's own enable flow, exactly as the ITF's phase-2 block runs it
    // (BANK4@0x1434-0x144C disassembled from the firmware pack: out 0x6A 07/21/68/06
    // brackets the mode select, then [0xE0102] = 1 before the fill): open the PEGC
    // MMIO view, write [0xE0102] = 1 through the register file (the dword at
    // 0xE0100 carries [0xE0100] = 0 - packed mode - in its low byte), close the view.
    pegc_256 = 1'b1;
    cpu_store(32'h000E_0100, 32'h0001_0000, 4'hF);
    pegc_256 = 1'b0;

    // ---- CHK-1: the ITF's 0xFFFFFFFF fill and verify over all 512 KiB. ----
    fill_verify(32'hFFFF_FFFF, 1);

    // ---- CHK-2: the ITF's 0x00000000 fill and verify over all 512 KiB. ----
    fill_verify(32'h0000_0000, 2);

    // ---- CHK-3: byte granularity. One byte into lane 0 at the base, one into lane 3 at
    // the top; the other three bytes of the word must stay 0x00. ----
    cpu_store(32'h00F0_0000, 32'h0000_00A5, 4'h1);
    cpu_store(32'h00F0_0004, 32'h5A00_0000, 4'h8);
    cpu_load(32'h00F0_0000, rd);
    if (rd !== 32'h0000_00A5) begin
      $display("FAIL CHK-3 lane 0: 0xF00000 read %08x, want 000000a5", rd);
      errors = errors + 1;
    end
    cpu_load(32'h00F0_0004, rd);
    if (rd !== 32'h5A00_0000) begin
      $display("FAIL CHK-3 lane 3: 0xF00004 read %08x, want 5a000000", rd);
      errors = errors + 1;
    end
    // and the storage itself carries them, so the CPU route did not fake the answer.
    if (backend.peek(PEG_BASE + 32'h0000_0000) !== 32'h0000_00A5 ||
        backend.peek(PEG_BASE + 32'h0000_0004) !== 32'h5A00_0000) begin
      $display("FAIL CHK-3 backend: PEG storage=%08x/%08x, want 000000a5/5a000000",
               backend.peek(PEG_BASE), backend.peek(PEG_BASE + 32'h4));
      errors = errors + 1;
    end

    // ---- CHK-4: the same address is NOT the PEGC store when the hole is off. 0x043B bit 2
    // set asks for 15-16 MiB RAM, so 0xF00000 is identity RAM (inside this bench's 16 MiB
    // guest) and the PEGC store keeps CHK-3's bytes. ----
    sys16m_en = 0;
    cpu_store(32'h00F0_0000, 32'hDEAD_BEEF, 4'hF);
    if (backend.peek(PEG_BASE) !== 32'h0000_00A5) begin
      $display("FAIL CHK-4 control: a store to 0xF00000 with the hole OFF reached the PEGC store (%08x)",
               backend.peek(PEG_BASE));
      errors = errors + 1;
    end else
      $display("  control: with the hole OFF 0xF00000 is RAM and the PEGC store is untouched");
    sys16m_en = 1;

    // ---- CHK-5: the hole's own remaining range is still no route at all. 0xF80000 must not
    // reach PEG storage nor be answered as the PEGC window. ----
    cpu_valid = 1; cpu_write = 1; cpu_addr = 32'h00F8_0000; cpu_din = 32'hCAFE_F00D;
    #1;
    if (!(mem_valid === 1'b0)) begin
      $display("FAIL CHK-5: 0xF80000 must stay the hole, got mem_valid=%b mem_addr=%08x",
               mem_valid, mem_addr);
      errors = errors + 1;
    end
    cpu_valid = 0; cpu_write = 0;

    // ---- CHK-6: the packed windows reach the same store at {bank, offset[14:0]}
    // (NP2kai memvga.c VGARD8/VGAWR8 `(mio1[p*2] & 15) << 15`; qemu pc98-vga.c
    // `(bank & 0x0f) * 0x8000`; MAME pegc_mmio_map `bank * 0x4000` words). Bank A
    // (0xE0004) serves the 0xA8000 window, bank B (0xE0006) the 0xB0000 window,
    // and both are windows into the SAME store the flat aperture reaches - which
    // is what makes DOOM's banked painting (docs/probes/PEGC.TXT: it set
    // 0xE0006 = 01 and painted through 0xB0000) visible on screen. ----
    pegc_256 = 1'b1;
    // bank A = 5, bank B = 3: the dword at 0xE0004 is {mio1[3..0]} = 00_03_00_05.
    cpu_store(32'h000E_0004, 32'h0003_0005, 4'hF);
    // window A: bank 5, offset 0x1234 -> store offset 5*0x8000 + 0x1234 = 0x29234.
    cpu_store(32'h000A_9234, 32'h55AA_A55A, 4'hF);
    // window B: bank 3, offset 0x0040 -> store offset 3*0x8000 + 0x0040 = 0x18040.
    cpu_store(32'h000B_0040, 32'h1122_3344, 4'hF);
    cpu_load(32'h00F2_9234, rd);
    if (rd !== 32'h55AA_A55A) begin
      $display("FAIL CHK-6 window A: 0xA9234 (bank 5) landed at 0xF29234 as %08x, want 55aaa55a", rd);
      errors = errors + 1;
    end
    cpu_load(32'h00F1_8040, rd);
    if (rd !== 32'h1122_3344) begin
      $display("FAIL CHK-6 window B: 0xB0040 (bank 3) landed at 0xF18040 as %08x, want 11223344", rd);
      errors = errors + 1;
    end
    // ... and the other direction: a store through the aperture is visible in the
    // banked window, so the two are one store and not two copies.
    cpu_store(32'h00F2_9238, 32'h0F1E_2D3C, 4'hF);
    cpu_load(32'h000A_9238, rd);
    if (rd !== 32'h0F1E_2D3C) begin
      $display("FAIL CHK-6 reverse: 0xF29238 read through window A as %08x, want 0f1e2d3c", rd);
      errors = errors + 1;
    end
    // The bank registers themselves round-trip (NP2kai memvgaio_rd8 returns the
    // stored byte; MAME masks the write to 4 bits - recorded, not asserted).
    cpu_load(32'h000E_0004, rd);
    if (rd !== 32'h0003_0005) begin
      $display("FAIL CHK-6 banks: 0xE0004 read %08x, want 00030005 (NP2kai mio1 round-trip)", rd);
      errors = errors + 1;
    end

    // ---- CHK-7: the TOP of the store, where the 640x480 256-colour frame ends. At the
    // Win95 PC-9821 driver's 1024-byte pitch (PEGCV8.DRV's mode row, seg 2 @0x0BCC) line 479
    // starts at 0x77C00, inside bank 14; bank 15 is the store's last 32 KiB. The driver
    // reaches the frame through the flat aperture (DPMI-mapped 0xF00000, seg 2 @0x0B7E) and
    // the 0xFFF00000 alias is the same store (NP2kai i386c/cpumem.c:805 memp_read8 `>=
    // 0xfff00000 && < 0xfff80000` -> memvgaf); the banked windows must see the same bytes. ----
    cpu_store(32'h000E_0004, 32'h000F_000E, 4'hF);           // bank A = 14, bank B = 15
    cpu_store(32'hFFF7_7C00, 32'hC0DE_4790, 4'hF);           // line 479, dot 0, via 0xFFF00000
    cpu_load(32'h000A_FC00, rd);                             // window A: 14*0x8000 + 0x7C00
    if (rd !== 32'hC0DE_4790) begin
      $display("FAIL CHK-7 high alias -> window A: 0xFFF77C00 read through 0xAFC00 (bank 14) as %08x, want c0de4790", rd);
      errors = errors + 1;
    end
    cpu_load(32'h00F7_7C00, rd);
    if (rd !== 32'hC0DE_4790) begin
      $display("FAIL CHK-7 high alias -> aperture: 0xFFF77C00 read at 0xF77C00 as %08x, want c0de4790", rd);
      errors = errors + 1;
    end
    cpu_store(32'h000B_7FFC, 32'h7FFF_C15F, 4'hF);           // window B, bank 15: the last dword
    cpu_load(32'hFFF7_FFFC, rd);
    if (rd !== 32'h7FFF_C15F) begin
      $display("FAIL CHK-7 window B -> high alias: 0xB7FFC (bank 15) read at 0xFFF7FFFC as %08x, want 7fffc15f", rd);
      errors = errors + 1;
    end
    cpu_load(32'h00F7_FFFC, rd);
    if (rd !== 32'h7FFF_C15F) begin
      $display("FAIL CHK-7 window B -> aperture: 0xB7FFC (bank 15) read at 0xF7FFFC as %08x, want 7fffc15f", rd);
      errors = errors + 1;
    end
    cpu_load(32'h000E_0004, rd);
    if (rd !== 32'h000F_000E) begin
      $display("FAIL CHK-7 banks: 0xE0004 read %08x, want 000f000e", rd);
      errors = errors + 1;
    end
    pegc_256 = 1'b0;

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PEGVRAM: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_PEGVRAM: FAIL (%0d errors)", errors);
  end
endmodule
