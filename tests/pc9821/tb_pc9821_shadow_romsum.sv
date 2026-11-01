`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_SHADOW_ROMSUM: an OSD reset no longer fails the ITF's own ROM sum. The window at 0xF8000-0xFFFFF has TWO layers -- the selected pack bank and a writable shadow in the SDRAM reserve above the pack -- and the gated STORE the ITF makes at 0xF8E90 goes to the shadow, never the pack, so the pack the sum reads stays pristine. The READ serves the shadow only while the shadow is enabled (0x043F's 0x8 nibble, reset-cleared) AND has been written since reset, so a boot that has not stored yet reads the pack.
//
// WHY. The authentic ITF sums the top window TWICE per POST. Both loops are byte-wise
// (lodsw / add dl,al / add dh,ah) over physical 0x0F8000-0x0FFFFF (the 32 KiB window) and
// 0x0E8000-0x0F7FFF (the fixed bios_lower slot); either non-zero sum makes BANK4@0x276
// print "ROM SUM ERROR" (the text starts at 0x2AEB; 0x2AEA is the 0x43 attribute byte) and
// halt. The first pass runs with the window still showing ROM. The ITF then enables the
// shadow (`out 0x43F,0x80`, BANK4@0x1D0), copies the window to RAM, sets the 0x053D bit-1
// gate, and at BANK4@0x262 jumps straight back into the two sums for a second pass -- with
// the shadow enabled and the gate open. THAT second pass is why this design needs the
// "written since reset" term and not just the enable: an unconditional shadow read would
// hand the second pass the previous boot's stored byte, and the sum would fail on every
// arm of the reset. Separately, the ITF computes a candidate-drive bitmap from port 0x0F0
// and stores it at 0xF8E90 (0x0E90), which the IDE option ROM later reads to decide which
// channels to probe.
//
// WHAT IS ASSERTED. The loader tees the BIOS-top bank into the shadow as it stages the
// pack; after a warm reset with NO re-download the first pass reads a pristine pack, the
// second pass (shadow enabled) still reads the pack, and the shadow's stale byte is
// therefore invisible to both -- while the option ROM, which reads after the ITF stores
// again in the same boot, still gets the stored 0x04. The pack's own cell is checked to be
// untouched, because a store landing there is what an OSD reset carried into the next
// boot's sum. The backend is sdram_backend_model, whose storage is untouched by reset (its
// reset arm resets the FSM only), so the byte's survival is a property of the shadow store,
// not of a bench that clears memory on reset.
//
// It also pins the ROM PACK's read-only invariant: with the 0x053D bit-1 gate OPEN
// a guest store into the 0xE8000-0xF7FFF window -- flat and through window 0 = 0x0E -- is
// rejected, so the byte the ITF's second ROM-sum pass reads at 0xE8000-0xF7FFF is still the
// pack's, both before and after an OSD reset. Atomic Punkers running from the IDE disk is
// what writes that window on the card.

module tb_pc9821_shadow_romsum;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // The memory-map function inputs. top_bank 9 is BANK_BIOS_TOP (bank_offset 0x20000), the
  // state the ITF's ROM sum selects with out 0x43D,2.
  reg [3:0]  top_bank = 4'd9;
  reg        bios_ram_gate = 0;
  // 0x043F's 0x8 nibble, latched in pc9821_iobus and cleared by reset. The bench drives it
  // by hand because it is testing the memory subsystem, not the port decode: on the card
  // the ITF installs it with `out 0x43F,0x80` before its store (BANK4@0x1D0/0x19CE).
  reg        top_shadow_en = 0;
  // 0x043F's 0x2 nibble; the identity, so nothing here is diverted to the EMS page.
  reg  [1:0] ems_state = 2'd0;
  reg [7:0]  win0_sel = 8'h08;
  reg [31:0] pack_base = 32'h0000_0000;
  reg [31:0] guest_ram_bytes = 32'h0100_0000;
  // Where pc9821_memory_subsystem puts the shadow. It USED to be pack_base + PACK_BYTES +
  // 0x10000 (0x110000 here), but the GVRAM moved back into SDRAM and now occupies the 256 KiB
  // reserve directly above the pack, so the EMS page and the shadow were pushed above the PCM
  // buffer: pack_base + PACK_BYTES + 0x58000. Read it from the DUT rather than copying the
  // arithmetic, so a layout move can never leave this bench peeking at the wrong address.
  wire [31:0] FW_SHADOW_BASE = dut.fw_shadow_base;

  // ioctl (the pack download: cold boot only).
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
  reg         ide_rom_enable = 0, gvram_access_page = 0;
  reg         grcg_we = 0;  reg [7:0] grcg_addr = 0, grcg_din = 0;
  reg         egc_enable = 0;  reg [15:0] egc_access = 0, egc_fgbg = 0, egc_ope = 0,
              egc_fg = 0, egc_mask = 0, egc_bg = 0, egc_sft = 0, egc_leng = 0;
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

  // The memory backend, at real sdram.v timing and with storage that outlives a reset.
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

  // ==== DUT ====
  pc9821_memory_subsystem #(.SYS_CLOCK_HZ(100_000_000)) dut (
      .scan_dot_ce(1'b0), .scan_dot_act(1'b1),
      .clk(clk), .reset(reset), .top_bank(top_bank),
      .ems_state(ems_state), .ide_rom_enable(ide_rom_enable), .d8_bank(2'b00), .ide_ram_gate(1'b1),
      .bios_ram_gate(bios_ram_gate), .top_shadow_en(top_shadow_en),
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
      .ACCEPT_TO_RESP(5), .WRITE_BUSY(3), .LINE_RESP(0), .WORDS_LOG2(20)
  ) backend (
      .clk(clk), .reset(reset), .valid(mem_valid), .ready(mem_ready),
      .write(mem_write), .addr(mem_addr), .din(mem_din), .din_hi(mem_din_hi), .be(mem_be), .gath(mem_gath), .gath_extra(mem_gath_extra),
      .burstcount(mem_burstcount), .dout(mem_dout), .resp_valid(mem_resp_valid),
      .busy(mem_busy), .accepts(mem_accepts), .beats(mem_beats)
  );

  integer errors = 0;

  // ==== STIMULUS ====
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

  // One CPU read through the mapper, bounded so a wedged route fails by name.
  task automatic cpu_read(input [31:0] a, output [31:0] d);
    integer g;
    begin
      @(negedge clk);
      cpu_addr = a; cpu_din = 32'd0; cpu_be = 4'hF;
      cpu_write = 0; cpu_line_read = 0; cpu_valid = 1;
      g = 0; while (!cpu_ready && g < 400) begin @(negedge clk); g = g + 1; end
      if (!cpu_ready) $fatal(1, "TB_PC9821_SHADOW_ROMSUM: no ready for read %08x", a);
      g = 0; while (!cpu_resp_valid && g < 400) begin @(negedge clk); g = g + 1; end
      if (!cpu_resp_valid) $fatal(1, "TB_PC9821_SHADOW_ROMSUM: no response for read %08x", a);
      d = cpu_dout;
      @(negedge clk); cpu_valid = 0;
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
      if (!cpu_ready) $fatal(1, "TB_PC9821_SHADOW_ROMSUM: no ready for write %08x", a);
      @(negedge clk); cpu_valid = 0;
      repeat (4) @(negedge clk);
    end
  endtask

  // The ITF's own sum: even-addressed bytes mod 256 and odd-addressed bytes mod 256. It
  // reads the BACKEND storage directly, which is what the ITF's sum reaches when the map
  // routes the window to the pack.
  integer even_sum, odd_sum;
  task automatic sum_window(input [31:0] base, input integer bytes);
    integer i;  reg [31:0] w;  reg [7:0] b;
    begin
      even_sum = 0; odd_sum = 0;
      for (i = 0; i < bytes; i = i + 1) begin
        w = backend.peek(base + i);          // byte address; peek picks the word
        b = w[8*i[1:0] +: 8];                // the byte lane this address selects
        if (i[0]) odd_sum = odd_sum + b; else even_sum = even_sum + b;
      end
    end
  endtask

  reg [31:0] rd;

  task automatic check_pack_top_pristine(input integer phase);
    begin
      sum_window(32'h0002_0000, 32'h8000);
      $display("  %0d top window sum (pack) even=%02x odd=%02x (the ITF requires 00/00)",
               phase, even_sum, odd_sum);
      if (even_sum != 0 || odd_sum != 0) begin
        $display("FAIL phase %0d: the pack's BIOS-top bank is not a zero-byte-sum ROM", phase);
        errors = errors + 1;
      end
    end
  endtask

  // ==== CHECKS ====
  initial begin
    // ---- COLD BOOT: download the pack. ----
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    ioctl_index = 16'd0;
    ioctl_download = 1;
    @(negedge clk);
    send_word(27'd0, 16'h1234);            // one word so saw_download latches and ready publishes
    // THE LOADER'S TEE: a BIOS-top word must reach the pack AND the shadow, so that an
    // offset the firmware never stores still reads as ROM through the shadow layer.
    send_word(27'h000_2_0E90, 16'h5A5A);
    ioctl_download = 0;
    repeat (12) @(posedge clk);
    if (!rom_ready || load_error)
      $fatal(1, "TB_PC9821_SHADOW_ROMSUM: pack did not publish ready (ready=%b err=%b)",
             rom_ready, load_error);
    if (backend.peek(FW_SHADOW_BASE + 32'h0000_0E90)[15:0] !== 16'h5A5A) begin
      $display("FAIL the loader did not tee pack[0x20E90] into the shadow (got %04x)",
               backend.peek(FW_SHADOW_BASE + 32'h0000_0E90)[15:0]);
      errors = errors + 1;
    end else begin
      $display("TEE   pack[0x20E90]=5A5A also staged at shadow[0x0E90]=5A5A");
    end
    // Put the top bank back to a zero-sum image so the sums below mean something: the pack
    // is rebuilt 0x00 and the tee follows it.
    ioctl_download = 1;
    @(negedge clk);
    send_word(27'h000_2_0E90, 16'h0000);
    ioctl_download = 0;
    repeat (12) @(posedge clk);

    // ---- PASS 1: the sums run BEFORE the ITF enables the shadow. ----
    top_shadow_en = 0;
    check_pack_top_pristine(1);
    cpu_read(32'h000F_8E90, rd);
    $display("  COLD 0xF8E90 read (shadow disabled) = %02x", rd[7:0]);
    if (rd[7:0] !== 8'h00) begin
      $display("FAIL the fresh top window is not 0x00 at 0xE90, got %02x", rd[7:0]);
      errors = errors + 1;
    end

    // ---- PASS 2: the ITF enables the shadow (out 0x43F,0x80) and jumps back to the sums. ----
    // Nothing has been stored since reset, so the map still serves the pack and both sums
    // stay 0x00/0x00.
    top_shadow_en = 1;
    check_pack_top_pristine(2);
    cpu_read(32'h000F_8E90, rd);
    $display("  COLD 0xF8E90 read (shadow enabled, not yet written) = %02x", rd[7:0]);
    if (rd[7:0] !== 8'h00) begin
      $display("FAIL shadow-enabled pre-store read is 0x%02x, want the pack's 0x00", rd[7:0]);
      errors = errors + 1;
    end

    // ---- THE ITF'S RUNTIME STORE: gate set (0x053D bit 1), 0x04 at 0xF8E90. ----
    bios_ram_gate = 1;
    cpu_write_byte(32'h000F_8E90, 8'h04);
    cpu_read(32'h000F_8E90, rd);
    if (rd[7:0] !== 8'h04) begin
      $display("FAIL runtime store: 0xF8E90 read back %02x, expected 04", rd[7:0]);
      errors = errors + 1;
    end else
      $display("STORE 0xF8E90 <- 04; the option ROM reads it back (shadow enabled + written)");

    // THE FIX ITSELF: the pack's own cell is untouched. A store landing there is what an
    // OSD reset carried into the next boot's sum.
    if (backend.peek(32'h0002_0E90)[7:0] !== 8'h00) begin
      $display("FAIL the store reached the pack: pack[0x20E90]=%02x, want 00",
               backend.peek(32'h0002_0E90)[7:0]);
      errors = errors + 1;
    end
    // THE ROM PACK IS READ-ONLY. The gate is OPEN (0x053D bit 1 set), the state
    // the machine runs in after POST and the state in which the pre-fix RTL wrote the pack.
    // A guest store into the 0xE8000-0xF7FFF lower-BIOS window must still be dropped, both
    // flat and through window 0 = 0x0E (0x88000 -> 0xE8000): NP2kai discards it
    // (cpumem.c:135 memnc_wr8), and a byte that reached pack_base+0x10000 shows up in the
    // sum below. Atomic Punkers running from the IDE disk is what lands here on the card.
    cpu_write_byte(32'h000E_8000, 8'hA5);
    win0_sel = 8'h0E;
    cpu_write_byte(32'h0008_8000, 8'h5A);
    win0_sel = 8'h08;
    if (backend.peek(32'h0001_0000)[7:0] !== 8'h00) begin
      $display("FAIL a guest store reached the pack's lower BIOS: pack[0x10000]=%02x, want 00",
               backend.peek(32'h0001_0000)[7:0]);
      errors = errors + 1;
    end
    // The bios_lower window is a fixed slot and must now sum to 00/00 (the ITF's second
    // ROM-sum pass reads exactly this 64 KiB). A store that landed breaks both bytes.
    sum_window(32'h0001_0000, 32'h8000);
    if (even_sum != 0 || odd_sum != 0) begin
      $display("FAIL bios_lower: a store perturbed the E8000 window (even=%02x odd=%02x)",
               even_sum, odd_sum);
      errors = errors + 1;
    end

    // ---- WARM RESET: the OSD Reset. NO re-download, exactly as the framework delivers it. ----
    bios_ram_gate = 0;
    top_shadow_en = 0;                     // 0x043F's latch resets with the platform
    reset = 1;
    repeat (4) @(posedge clk);
    reset = 0;
    repeat (12) @(posedge clk);
    if (!rom_ready)
      $fatal(1, "TB_PC9821_SHADOW_ROMSUM: the loader did not keep rom_ready across the warm reset");

    // PASS 1 of the new boot.
    check_pack_top_pristine(3);
    // The lower-BIOS slot the ITF's SECOND sum reads is still the pack's ROM after the reset:
    // the rejected store left no byte in it. This is the Atomic Punkers sequence --
    // run, store into the ROM window, OSD reset, and the next boot's sum must pass.
    sum_window(32'h0001_0000, 32'h8000);
    if (even_sum != 0 || odd_sum != 0) begin
      $display("FAIL post-reset bios_lower sum even=%02x odd=%02x (a ROM-window store survived the reset)",
               even_sum, odd_sum);
      errors = errors + 1;
    end

    // PASS 2 of the new boot: the ITF writes 0x043F=0x80 again, and the shadow still HOLDS
    // the previous boot's 0x04 -- but the dirty flag reset with the platform, so the map
    // serves the pack and the sum stays 0x00/0x00. This is the regression the fix closes.
    top_shadow_en = 1;
    if (backend.peek(FW_SHADOW_BASE + 32'h0000_0E90)[7:0] !== 8'h04) begin
      $display("FAIL the shadow lost the stored byte across the reset: shadow[0x0E90]=%02x",
               backend.peek(FW_SHADOW_BASE + 32'h0000_0E90)[7:0]);
      errors = errors + 1;
    end
    cpu_read(32'h000F_8E90, rd);
    $display("  WARM 0xF8E90 read (shadow enabled, stale 04 present) = %02x", rd[7:0]);
    if (rd[7:0] !== 8'h00) begin
      $display("FAIL the warm boot's second pass read the shadow's stale 0x%02x, want the pack's 0x00",
               rd[7:0]);
      errors = errors + 1;
    end
    check_pack_top_pristine(4);

    // The option ROM in the NEW boot still sees the store once the ITF makes it again.
    bios_ram_gate = 1;
    cpu_write_byte(32'h000F_8E90, 8'h04);
    cpu_read(32'h000F_8E90, rd);
    $display("  WARM option-ROM read after the new store = %02x", rd[7:0]);
    if (rd[7:0] !== 8'h04) begin
      $display("FAIL the warm boot's option-ROM read is 0x%02x, want the stored 0x04", rd[7:0]);
      errors = errors + 1;
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SHADOW_ROMSUM: PASS");
      $finish;
    end else $fatal(1, "TB_PC9821_SHADOW_ROMSUM: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog, so a hang is a named failure rather than a runner timeout.
  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_SHADOW_ROMSUM: FAIL (watchdog: the bench did not finish)");
  end

endmodule
