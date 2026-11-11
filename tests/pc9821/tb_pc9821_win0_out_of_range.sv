`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// A window-0 access whose TARGET page is not guest RAM behaves exactly like the direct encoding of that page (aliases.md A6): past guest_ram_bytes both are open bus with stores discarded, and under sys16m with win0 over 0xF00000-0xF7FFFF both reach the PEGC EVRAM at peg_base. out_of_range used to test cpu_addr (0x80000, inside RAM) instead of the biased d_addr, so the fallthrough emitted raw d_addr and the overlay reached ordinary SDRAM behind the map. FAIL-FIRST: the overlay's store lands in SDRAM and reads back where the direct encoding reads F's, and the two encodings disagree byte for byte over the PEGC window. A window page below 8 is a hole on the real Xe10 (docs/probes/KIT2-XE10-RISKY-461.TXT:5-17, RISKY /461): with 0x0461 = 00, 02, 04 or 06 every window word at 0x80000-0x9FFFC reads FFFFFFFF while the conventional memory the page names keeps its contents, and a store through the window at pages 00 and 02 never reaches that memory, while page 08 is the identity - FAIL-FIRST, the core aliased the conventional memory there.
//
// A window-0 (0x0461) access whose TARGET page is not guest RAM behaves exactly like the
// direct encoding of that page: the overlay must not reach ordinary SDRAM where the direct
// encoding serves open bus (past guest_ram_bytes), and it must reach the PEGC EVRAM where
// the direct encoding serves the PEGC window (win0 over 0xF00000-0xF7FFFF with sys16m on).
// The defect (aliases.md A6) was out_of_range testing cpu_addr (0x80000, inside RAM) instead
// of the biased d_addr (the target), so the fallthrough emitted raw d_addr to the backend.
//
// FAILS BEFORE: the overlay's store lands in SDRAM at the target and reads back through the
// overlay while the direct encoding reads F's (case 1), and the overlay reaches SDRAM at
// 0xF00000 while the direct encoding reads PEGC EVRAM (case 2).
// PASSES AFTER: both encodings agree on every check, and no store reaches the wrong storage.

`default_nettype none

module tb_pc9821_win0_out_of_range;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;
  reg [3:0] top_bank = 4'd8;
  reg ide_rom_enable = 0;
  reg bios_ram_gate = 0;
  reg top_shadow_en = 0;
  reg  soft_reboot = 1'b0;   // no reboot strobe in this bench
  reg [7:0] win0_sel = 8'h08;
  reg  sys16m_en = 1'b0;
  reg [31:0] pack_base = 32'h0010_0000;
  reg [31:0] guest_ram_bytes = 32'h0010_0000;
  reg gvram_access_page = 0;
  reg        egc_enable = 1'b0;
  reg [15:0] egc_access = 16'hFFF0;
  reg [15:0] egc_fgbg = 16'h00FF;
  reg [15:0] egc_ope = 16'h0000;
  reg [15:0] egc_fg = 16'h0000;
  reg [15:0] egc_mask = 16'hFFFF;
  reg [15:0] egc_bg = 16'h0000;
  reg [15:0] egc_sft = 16'h0000;
  reg [15:0] egc_leng = 16'h000F;
  reg        egc_shift_we = 1'b0;
  reg ioctl_download = 0, ioctl_wr = 0;
  reg [15:0] ioctl_index = 0;
  reg [26:0] ioctl_addr = 0;
  reg [15:0] ioctl_dout = 0;
  wire ioctl_wait, rom_ready, load_error, cpu_run;
  wire [17:0] font_addr;
  wire [15:0] font_data;
  wire font_we;

  reg [31:0] cpu_addr = 0, cpu_din = 0;
  wire [31:0] cpu_dout;
  wire [31:0] cpu_line_word;
  reg [3:0] cpu_be = 4'hF;
  reg [7:0] cpu_burstcount = 1;
  reg cpu_line_read = 0, cpu_valid = 0, cpu_write = 0;
  wire cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  wire [13:0] tram_addr;
  wire [7:0] tram_din;
  wire tram_we;
  reg [7:0] tram_dout = 0;
  wire [4:0] cg_win_byte_sel;
  wire cg_win_rd;
  reg [7:0] cg_win_dout = 0;
  wire [7:0] cg_win_din;
  wire cg_win_we;
  wire cg_win_byte_hold = 1'b0;
  reg [18:0] font_req_addr = 0;
  reg font_req = 0;
  wire font_word_valid;
  wire [31:0] font_word_data;
  wire [31:0] fmem_addr, fmem_din;
  wire fmem_valid, fmem_write;
  wire [3:0] fmem_be;
  wire [7:0] fmem_burstcount;
  reg fmem_ready = 1, fmem_resp_valid = 0;
  reg [31:0] fmem_dout = 32'd0;

  wire [31:0] mem_addr, mem_din, mem_din_hi;
  // The G3 gather session's qualifier and entries (pc9821_memory_subsystem's
  // mem_gath* outputs, carried into the model so a grouped drain applies all its entries).
  wire        mem_gath;
  wire [440:0] mem_gath_extra;
  wire [31:0] mem_dout;
  wire [3:0] mem_be;
  wire [7:0] mem_burstcount;
  wire mem_valid, mem_write;
  wire mem_ready, mem_resp_valid;
  wire mem_line_dout_unused_ok;
  wire [127:0] mem_line_dout;
  wire mem_line_resp_valid;
  wire [31:0] mem3_addr = 0, mem3_din;
  wire  [3:0] mem3_be = 0;
  wire  [7:0] mem3_burstcount = 0;
  wire        mem3_valid = 0, mem3_write = 0;
  reg  [31:0] mem3_dout = 32'h0;
  reg         mem3_ready = 1, mem3_resp_valid = 0;

  reg        grcg_we = 0;
  reg  [7:0] grcg_addr = 0;
  reg  [7:0] grcg_din = 0;
  wire       grcg_expand;
  reg        scan_enable = 0;
  reg        scan_line_tick = 0;
  reg        scan_page = 0;
  reg        scan_walk_page = 0;
  reg [14:0] scan_line_base = 0;
  reg  [6:0] line_rd_addr = 0;
  reg        line_rd_sel = 0;
  wire [31:0] line_data;
  wire        line_sel;
  wire        line_ready;
  wire [1:0] ems_state;

  wire [127:0] dbg_gfx_stats;
  wire dbg_walk_start, dbg_walk_cycle;
  wire dbg_egc_txn, dbg_egc_unit, dbg_grcg_store;
  wire dbg_gr_owned, dbg_eg_owned;
  wire dbg_access_page, dbg_scan_page_q;

  // ==== DUT ====
  // The PEGC view select (pc9821_crtc's mode2_256col): opened only for the
  // [0xE0102] aperture-enable write (the machine's own flow), then closed.
  reg        pegc_256 = 1'b0;
  // The 16-colour select (port 0x6A FF2 num 0): 0 = the digital mode the machine resets to,
  // where 0xE0000-0xE7FFF is open bus (pc9821_memory_map e_plane_nc).
  reg        mode2_16color = 1'b0;
  pc9821_memory_subsystem #(.SYS_CLOCK_HZ(100_000_000)) dut (
      .mode2_16color(mode2_16color),
      .scan_dot_ce(1'b0), .scan_dot_act(1'b1),
      .clk(clk), .reset(reset),
      .top_bank(top_bank), .ems_state(ems_state),
      .ide_rom_enable(ide_rom_enable), .d8_bank(2'b00), .ide_ram_gate(1'b1), .bios_ram_gate(bios_ram_gate),
      .top_shadow_en(top_shadow_en), .soft_reboot(soft_reboot), .win0_sel(win0_sel), .win0_sel_moved(win0_sel != 8'h08), .sys16m_en(sys16m_en),
      .pegc_256(pegc_256),
      .pack_base(pack_base), .guest_ram_bytes(guest_ram_bytes),
      .gvram_access_page(gvram_access_page),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din),
      .grcg_expand(grcg_expand),
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
      .font_req_addr(font_req_addr), .font_req(font_req),
      .font_word_valid(font_word_valid), .font_word_data(font_word_data),
      .fmem_addr(fmem_addr), .fmem_din(fmem_din), .fmem_valid(fmem_valid),
      .fmem_write(fmem_write), .fmem_be(fmem_be),
      .fmem_burstcount(fmem_burstcount), .fmem_ready(fmem_ready),
      .fmem_dout(fmem_dout), .fmem_resp_valid(fmem_resp_valid),
      .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_dout(cpu_dout),
      .cpu_be(cpu_be),
      .cpu_burstcount(cpu_burstcount), .cpu_line_read(cpu_line_read),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .tram_addr(tram_addr), .tram_din(tram_din), .tram_we(tram_we),
      .tram_dout(tram_dout),
      .cg_win_byte_sel(cg_win_byte_sel), .cg_win_rd(cg_win_rd),
      .cg_win_dout(cg_win_dout), .cg_win_din(cg_win_din), .cg_win_we(cg_win_we),
      .cg_win_byte_hold(cg_win_byte_hold),
      .mem_addr(mem_addr), .mem_din(mem_din), .mem_din_hi(mem_din_hi), .mem_gath(mem_gath), .mem_gath_extra(mem_gath_extra), .sdram_size(2'd2),
      .mem_dout(mem_dout),
      .mem_be(mem_be), .mem_burstcount(mem_burstcount),
      .mem_valid(mem_valid), .mem_write(mem_write),
      .mem_ready(mem_ready), .mem_resp_valid(mem_resp_valid),
      .dbg_gfx_stats(dbg_gfx_stats),
      .dbg_walk_start(dbg_walk_start), .dbg_walk_cycle(dbg_walk_cycle),
      .dbg_egc_txn(dbg_egc_txn), .dbg_egc_unit(dbg_egc_unit),
      .dbg_grcg_store(dbg_grcg_store),
      .dbg_gr_owned(dbg_gr_owned), .dbg_eg_owned(dbg_eg_owned),
      .dbg_access_page(dbg_access_page), .dbg_scan_page_q(dbg_scan_page_q)
  );

  sdram_backend_model #(
      .ACCEPT_TO_RESP(2), .WRITE_BUSY(2), .LINE_RESP(0), .WORDS_LOG2(22)
  ) backend (
      .clk(clk), .reset(reset), .valid(mem_valid), .ready(mem_ready),
      .write(mem_write), .addr(mem_addr), .din(mem_din), .din_hi(32'd0), .gath(mem_gath), .gath_extra(mem_gath_extra),
      .be(mem_be), .burstcount(mem_burstcount),
      .dout(mem_dout), .resp_valid(mem_resp_valid),
      .line_dout(mem_line_dout), .line_resp_valid(mem_line_resp_valid),
      .busy(), .accepts(), .beats()
  );

  integer errors = 0;
  reg [31:0] rd, rd2;

  // ==== CHECKS ====
  task automatic chk(input [31:0] got, input [31:0] want, input [8*120-1:0] tag);
    begin
      if (got !== want) begin
        $display("FAIL %0s: got %08x, want %08x", tag, got, want);
        errors = errors + 1;
      end
    end
  endtask

  task automatic req(input [31:0] a, input wr, input [31:0] wd, output [31:0] rdata);
    integer g;
    begin
      @(negedge clk);
      cpu_addr = a; cpu_din = wd; cpu_write = wr; cpu_be = 4'hF;
      cpu_burstcount = 8'd1; cpu_line_read = 0; cpu_valid = 1;
      g = 0;
      while (!cpu_ready && g < 5000) begin @(negedge clk); g = g + 1; end
      if (!cpu_ready) $fatal(1, "TB_PC9821_WIN0_OUT_OF_RANGE: no accept for %08x", a);
      rdata = 32'h0;
      if (!wr) begin
        g = 0;
        while (!cpu_resp_valid && g < 5000) begin @(negedge clk); g = g + 1; end
        if (!cpu_resp_valid)
          $fatal(1, "TB_PC9821_WIN0_OUT_OF_RANGE: no response for %08x", a);
        rdata = cpu_dout;
      end
      @(negedge clk);
      cpu_valid = 0; cpu_write = 0;
      repeat (4) @(posedge clk);
    end
  endtask

  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_WIN0_OUT_OF_RANGE: TIMEOUT");
  end

  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk);
    reset = 0;
    // The minimal download pulse: saw_download -> rom_ready -> cpu_run, exactly
    // as tb_pc9821_memory_subsystem releases the bus.
    @(negedge clk);
    ioctl_download = 1;
    repeat (2) @(negedge clk);
    ioctl_download = 0;
    repeat (4) @(negedge clk);
    if (!rom_ready || !cpu_run)
      $fatal(1, "TB_PC9821_WIN0_OUT_OF_RANGE: the pack did not release the CPU");

    // ==== Case 1 (A6): win0=0x20 at 1 MiB -- the target page is past RAM ====
    // The direct encoding of 0x200000 is open bus (stores discarded); the overlay
    // must be the same thing, not ordinary SDRAM behind the map.
    win0_sel = 8'h20;
    req(32'h0008_0000, 1'b1, 32'h1234_5678, rd);
    req(32'h0008_0000, 1'b0, 32'h0, rd);
    chk(rd, 32'hFFFF_FFFF,
        "A6: overlay at 0x80000 (win0=0x20 past RAM) reads open bus");
    req(32'h0020_0000, 1'b0, 32'h0, rd);
    chk(rd, 32'hFFFF_FFFF,
        "A6: direct encoding 0x200000 reads open bus");
    if (backend.peek(32'h0020_0000) !== 32'h0000_0000) begin
      $display("FAIL A6: the overlay's store landed in SDRAM at 0x200000: %08x",
               backend.peek(32'h0020_0000));
      errors = errors + 1;
    end

    // ==== Case 2 (A6): win0=0xF0 under sys16m -- the target is the PEGC window ====
    // The direct encoding serves PEGC EVRAM at peg_base; the overlay must reach
    // the SAME bytes, not raw SDRAM at 0xF00000. The aperture is gated by the
    // register file's [0xE0102] bit 0 (NP2kai memvgaf; MAME pegc_vram_view), so the
    // machine's own enable flow runs first: open the view, write 0xE0102 = 1
    // through the register file, close it.
    pegc_256 = 1'b1;
    req(32'h000E_0100, 1'b1, 32'h0001_0000, rd);
    pegc_256 = 1'b0;
    guest_ram_bytes = 32'h0200_0000;
    sys16m_en = 1'b1;
    win0_sel = 8'hF0;
    req(32'h0008_0000, 1'b1, 32'hCAFE_BABE, rd);
    req(32'h0008_0000, 1'b0, 32'h0, rd);
    req(32'h00F0_0000, 1'b0, 32'h0, rd2);
    chk(rd, rd2, "A6: overlay 0x80000 agrees with direct 0xF00000 (PEGC)");
    chk(rd, 32'hCAFE_BABE, "A6: the PEGC EVRAM byte carries the overlay's store");
    if (backend.peek(32'h00F0_0000) !== 32'h0000_0000) begin
      $display("FAIL A6: the overlay's store landed in raw SDRAM at 0xF00000: %08x",
               backend.peek(32'h00F0_0000));
      errors = errors + 1;
    end

    // ==== Case 3: pages 00-06 are a hole (docs/probes/KIT2-XE10-RISKY-461.TXT:5-17) ====
    // `R461 00 rb=01 win(80000 80400 90000 9FFFE)=FFFF FFFF FFFF FFFF dir=B625 7002 0001 82E8
    // mark(win before/after, cell)=FFFF FFFF 3C5A`: the window reads FFFF where the page's own
    // memory holds data, and the marker stored through it never reaches the cell. Pages 02, 04
    // and 06 read FFFF likewise (lines 9-15); page 08 is the identity (line 17).
    sys16m_en = 1'b0;
    win0_sel = 8'h08;
    req(32'h0000_0000, 1'b1, 32'h7002_B625, rd);
    req(32'h0001_0000, 1'b1, 32'h82E8_0001, rd);
    req(32'h0002_0400, 1'b1, 32'hA282_4558, rd);
    req(32'h0006_FFFC, 1'b1, 32'h0606_0606, rd);
    req(32'h0008_0000, 1'b1, 32'h3A41_0808, rd);
    win0_sel = 8'h00;
    req(32'h0008_0000, 1'b0, 32'h0, rd);
    chk(rd, 32'hFFFF_FFFF, "R461 00: the window at 0x80000 reads FFFF FFFF");
    req(32'h0009_0000, 1'b0, 32'h0, rd);
    chk(rd, 32'hFFFF_FFFF, "R461 00: the window at 0x90000 reads FFFF FFFF");
    req(32'h0008_0000, 1'b1, 32'hC3A5_C3A5, rd);
    req(32'h0008_0000, 1'b0, 32'h0, rd);
    chk(rd, 32'hFFFF_FFFF, "R461 00: the marker reads back FFFF FFFF through the window");
    win0_sel = 8'h02;
    req(32'h0008_0400, 1'b0, 32'h0, rd);
    chk(rd, 32'hFFFF_FFFF, "R461 02: the window at 0x80400 reads FFFF FFFF");
    req(32'h0008_0400, 1'b1, 32'h5A5A_5A5A, rd);
    win0_sel = 8'h04;
    req(32'h0009_FFFC, 1'b0, 32'h0, rd);
    chk(rd, 32'hFFFF_FFFF, "R461 04: the window at 0x9FFFC reads FFFF FFFF");
    win0_sel = 8'h06;
    req(32'h0008_FFFC, 1'b0, 32'h0, rd);
    chk(rd, 32'hFFFF_FFFF, "R461 06: the window at 0x8FFFC reads FFFF FFFF");
    win0_sel = 8'h08;
    req(32'h0000_0000, 1'b0, 32'h0, rd);
    chk(rd, 32'h7002_B625, "R461 00: the page's own memory kept its word (dir)");
    req(32'h0002_0400, 1'b0, 32'h0, rd);
    chk(rd, 32'hA282_4558, "R461 02: the store through the hole never reached 0x20400");
    req(32'h0008_0000, 1'b0, 32'h0, rd);
    chk(rd, 32'h3A41_0808, "R461 08: page 08 is the identity");

    // ==== Controls: a RAM-target window and direct RAM are untouched ====
    win0_sel = 8'h20;
    req(32'h0008_0000, 1'b1, 32'h0BAD_C0DE, rd);
    req(32'h0008_0000, 1'b0, 32'h0, rd);
    req(32'h0020_0000, 1'b0, 32'h0, rd2);
    chk(rd, 32'h0BAD_C0DE, "control: win0=0x20 at 32 MiB reads back through the overlay");
    chk(rd2, 32'h0BAD_C0DE, "control: direct 0x200000 sees the same RAM");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_WIN0_OUT_OF_RANGE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_WIN0_OUT_OF_RANGE: FAIL (%0d errors)", errors);
  end
endmodule

`default_nettype wire
