`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GDC_TEXT:
// The text GDC's character-generator paths: user CG RAM and the ANK fetch through the CG window including the row bit, the code register packing, and the tile/colour registers as readback. It also renders JIS kanji from the pack's FONT.ROM copy as a two-cell pair (left half then right half) at the dump's own address 0x1800 + (ku-0x21)*0xC00 + (ten-0x20)*0x20, with a spread of glyphs from the symbol, kana, level-1 and level-2 rows checked byte for byte against the dump, the pair's second cell drawing its half with no code of its own, and a pair never crossing a line. The GRCG's own mode/tile registers are no longer latched here (pc9821_grcg owns them and their four-plane write path, asserted by tb_pc9821_grcg.sv); what this bench still pins is the port-level fact that 0x7C/0x7E read 0xFF. No assertion here can see a colour swap in the pixel path. It also pins the port 0xA9 read answering the glyph byte of the code the guest just wrote rather than the previous code's asynchronous SDRAM block (the stale-glyph bug a driver's glyph loop hit). It also pins the CODE plane's 12-bit word index: with a display start (PRAM screen 0) of 0x1000 words - further than any word the boot configuration's 80x25 screen reaches - a plane holding one 2-byte code in every word and 0xE1 in every attribute byte must still fetch the code and draw the glyph, where a 13-bit code index reads the ATTRIBUTE plane as the code and the whole screen draws blank. It also pins the port-0xA4 display-page flip as an IMMEDIATE page-select: a write reaches the scan page on the next clk_sys wherever in the frame it lands - early on the last line, in the last dots before frame_end, and mid active region - because 0xA4 is a page-select mux outside the GDC (MAME/NP2kai/QEMU all apply it at the write, and the real-machine probe shows the tear), reversing an earlier frame-boundary latch. The machine-reset seed is pinned on this same record: pc9821_system re-seeds it from the iobus's reset-seed one-shot (one event for both configuration stores), and because pc9821_cg's own reset is clamped for the whole machine-reset window the walk must NOT be reset-held - a strobe landing INSIDE that window restores all 38 bytes (the 14-byte record first, then the mirror's 24) and is quiet within 40 clk_sys, so the record is whole before the CPU can leave its own reset and read the ITF's 0xFC681 marker (FAIL-FIRST: with the walk under `!rst_n_sys` the strobe is swallowed and the corrupt record survives the reset). It also pins the DIP PORT MIRROR at CG store 0x40..0x5B (code 0x0156), the 24 bytes BANK4@0xFC42D copies into the software-DIP ports during POST: bank A must sit at 0x50..0x5B and bank B at 0x40..0x4B - the swap the BANK3@0x2322 accessor helper encodes - each byte the machine DIP image of its row (bank A docs/probes/PORTS.TXT:258 (841E 7C 851E 02 861E 76 871E 3E), bank B the BANK4@0x4818 factory table), and every byte the ITF's odd-parity verify examines must satisfy it (FAIL-FIRST: the unseeded mirror is 24 even-parity zeroes, which that verify rejects at once); the same one restore walk re-seeds the mirror too, record first and whole within 40 clk_sys. With MODE FF1 bit 0 set, an ANK cell whose attribute has bit 4 draws its code as NP2kai's simple-graphics 2x4 block pattern (maketext.c's TXTATR_BG arm, font.c font_setchargraph, the NEC 0xF2 patch included) instead of the ANK glyph, and with bit 0 clear the same attribute bit is the vertical line again. It also renders the ver0.78 half-width rows (ku 0x29-0x2B): NP2kai draws those as a SINGLE cell, the grid slot's left half with no pair consumption (vram/maketext.c:280-296 leaves kanji2nd clear for kc 0x09-0x0B), checked raster for raster against FONT.ROM[0x7C20]'s own 'A' and against a tagged asymmetric glyph so a pair-consuming fix cannot pass (FAIL-FIRST: the pre-fix scanout drew nothing there).


module tb_pc9821_gdc_text;
  reg clk_sys = 0;
  always #5 clk_sys = ~clk_sys;
  wire clk_vid = clk_sys;
  reg pixel_ce = 1;
  reg rst_n_sys = 0, rst_n_vid = 0;
  reg io_wr = 0;
  reg io_rd = 0;
  reg [7:0] io_addr = 0, io_din = 0;
  wire gfx_access_page;
  // GDC2 SCROLL display start (see pc9821_gdc_text); the bench that asserts it is
  // tb_pc9821_gdc2_scroll, so it is only parked here to keep (.*) complete.
  wire [15:0] gfx_line_addr;
  wire gfx_walk_page;   // the packed walk's page bit; asserted in tb_pc9821_gdc2_scroll, parked here for (.*)
  wire [7:0] io_dout;
  reg [13:0] tram_cpu_addr = 0;
  reg [7:0] tram_cpu_din = 0;
  reg tram_cpu_we = 0;
  wire [7:0] tram_cpu_dout;
  // CG window byte port: the window itself is exercised end-to-end by
  // tb_pc9821_cg_window; here it is parked so (.*) stays complete.
  reg  [4:0] cg_win_byte_sel = 0;
  reg  cg_win_rd = 0;
  wire [7:0] cg_win_dout;
  reg  [7:0] cg_win_din = 0;
  reg  cg_win_we = 0;
  // Glyph-region fetch (the pack's FONT.ROM copy): driven by its own bench,
  // parked here.
  wire [18:0] font_req_addr;
  wire font_req;
  reg  font_word_valid = 0;
  reg  [31:0] font_word_data = 0;
  reg [17:0] font_ld_addr = 0;
  reg [15:0] font_ld_data = 0;
  reg font_ld_we = 0;
  // The CG block's variable read wait: the JIS read comes from SDRAM now, so the
  // bench's fmem stub below must answer the walker before the scanout samples.
  wire vsync_active, disp_on;
  // The configuration-image seed (pc9821_gdc_text's cfg_* block / pc9821_iobus's memory-switch
  // strap cell): 0 = no seed, which is what this bench wants. tb_pc9821_cg_read_path drives it.
  wire [6:0] cfg_ram_mib = 7'd0;
  wire       cfg_seed_en = 1'b0;
  wire       cfg_seed_reload = 1'b0;
  wire gfx_disp;   // the slave GDC's display latch, asserted by the case below
  wire vsync_irq_arm, vsync_irq;
  wire vsync_edge;   // the frame boundary the IRQ rises on; parked so (.*) stays complete
  // The text plane now leaves the GDC as a colour and two opacity flags, not as
  // an RGB byte. Reconstructing the old byte here keeps this bench's
  // lit-dot assertions exactly as they were.
  wire        text_opaque, text_cell;
  wire [11:0] text_colour;
  wire [9:0]  pix_dot;
  wire        pix_h_active, pix_v_active;
  wire        gfx_mode16;
  wire [31:0] gfx_dig;
  // The analogue palette table's CPU write port (pc9821_gfx_palette's MLAB).
  wire        pal_wr_en;
  wire [3:0]  pal_wr_idx;
  wire [1:0]  pal_wr_chan;
  wire [3:0]  pal_wr_data;
  wire        pal_commit;
  wire [7:0]  r_out = text_opaque ? {text_colour[11:8], text_colour[11:8]} : 8'h00;
  wire [7:0]  g_out = text_opaque ? {text_colour[7:4],  text_colour[7:4]}  : 8'h00;
  wire [7:0]  b_out = text_opaque ? {text_colour[3:0],  text_colour[3:0]}  : 8'h00;
  wire hs_out, vs_out, de_out;

  // OSD "Reset DIPs"/"Zero DIPs" one-cycle pulses into the CG-record restore.
  reg cg_record_restore = 0;
  reg [3:0] bios_set = 4'd0;   // the record's model field: 0 = Xe10 (entry 0)
  // The EGC gate this module exports (FF2 num 2 AND 0x7C bit 7). Its consumer is
  // pc9821_egc in the memory path, which this bench does not build; the bench
  // still checks the gate's own inputs' effects on the exported wire.
  wire gfx_egc_gate;

  integer irq_pulses = 0;
  // The three analogue channels read back through the port, in the mirror's own byte order
  // {B, R, G} (the white-box peep this replaced was `dut.u_crtc.pal_mirror[3]`).
  reg [23:0] rgb_rd = 24'h0;
  // The raster line each VSYNC event happens on. `in_vsync` is the raw pulse, decoded
  // combinationally from `vline`, and the vline register only advances on the pixel enable, so
  // reading dut.u_crtc.vline at the first clk_sys edge the pulse is high names the LINE the pulse rose on
  // (407 = VACTIVE + VFP) however many clk_sys the domain crossing costs. `irq_vline` is the same
  // read at the armed IRQ's own edge, which is one to two clk_sys later: 407 or 408 when the IRQ is
  // on the pulse's rising edge, and 400 if it were on the top of blanking. That is the difference
  // the phase question is about, and it is what makes this check fail on the other answer.
  reg [9:0] pulse_vline = 10'd0, irq_vline = 10'd0;
  reg       in_vsync_d = 1'b0;
  always @(posedge clk_sys) begin
    in_vsync_d <= dut.u_crtc.in_vsync;
    if (dut.u_crtc.in_vsync && !in_vsync_d) pulse_vline <= dut.u_crtc.vline;
    if (vsync_irq) irq_vline <= dut.u_crtc.vline;
  end
  always @(posedge clk_sys) begin
    if (vsync_irq) irq_pulses = irq_pulses + 1;
  end

  // Mirrors pc9821_system.sv: any write to port 0x64 arms the latch.
  assign vsync_irq_arm = io_wr && (io_addr == 8'h64);

  // Build-up telemetry taps (see pc9821_system's watchdog message).
  wire [15:0] dbg_sad;
  wire  [7:0] dbg_pitch;
  wire        dbg_col40, dbg_disp;
  wire [15:0] dbg_wk_skips;   // the walker's skipped-walk counter

  // ==== DUT ====
  wire cg_rd_hold, cg_win_byte_hold;
  // Parked: the 200-line interleave's odd-line output (pc9821_crtc's seam; this bench
  // does not check it - tb_pc9821_interleave_200 does).
  wire gfx_odd_line;
  // The ONE OSD hardware-switch field, as a LIST POSITION at ENTRY 0 - the measured
  // machine's own boot/FDD nibble (0x00). pc9821_crtc decodes and latches it and seeds its
  // TRAM tail at machine reset; it is declared so the wildcard `.*` instance below connects
  // it rather than leaving the port at zero. The base memory is hardcoded to 640 KB inside
  // pc9821_crtc.
  reg [2:0] cfg_fdd_mode = 3'd0;

  pc9821_gdc_text_dut dut (.*);

  integer i, errors = 0;
  reg [7:0] value;

  // ---- the JIS spread sample set (see the spread section at the end) ----
  // One glyph from a symbol row, the kana rows, the first and last level-1 rows and the
  // first, a middle and the last level-2 row. Each 256-bit record is the 32-byte glyph
  // FONT.ROM[0x1800 + (ku-0x21)*0xC00 + (ten-0x20)*0x20 .. +32) with dump byte 0 in bits [7:0],
  // read straight out of bios/xe10/FONT.ROM: the dump is the oracle, not a model of it.
  localparam integer NSPREAD = 8;
  reg [7:0]    sp_ku    [0:NSPREAD-1];
  reg [7:0]    sp_ten   [0:NSPREAD-1];
  reg [255:0]  sp_glyph [0:NSPREAD-1];
  initial begin : sp_init
    sp_ku[0] = 8'h22; sp_ten[0] = 8'h21;   // FONT.ROM[0x02420] (store word 3600)
    sp_glyph[0] = 256'h000080c0e0f0f8fcfefcf8f0e0c080000000000103070f1f3f1f0f0703010000;
    sp_ku[1] = 8'h24; sp_ten[1] = 8'h22;   // FONT.ROM[0x03c40] (word 6688)
    sp_glyph[1] = 256'h00e01804828242424cf0008070080000000018262111120a0702020f11010200;
    sp_ku[2] = 8'h26; sp_ten[2] = 8'h21;   // FONT.ROM[0x05420] (word 9744)
    sp_glyph[2] = 256'h00000e040408f81010202040408080000000381010080f040402020101000000;
    sp_ku[3] = 8'h30; sp_ten[3] = 8'h21;   // FONT.ROM[0x0cc20] (word 25104)
    sp_glyph[3] = 256'hff202020fe2222222222fe202020fe007f0202023f22222222223f0202023f00;
    sp_ku[4] = 8'h4f; sp_ten[4] = 8'h21;   // FONT.ROM[0x24020] (word 72720)
    sp_glyph[4] = 256'hff2020ff20fe22fe22fe20ff2020ff20432c1017107302132243102740027f02;
    sp_ku[5] = 8'h50; sp_ten[5] = 8'h26;   // FONT.ROM[0x24cc0] (word 74336)
    sp_glyph[5] = 256'h0000000000202040408000000000000000000000000000000000010200000000;
    sp_ku[6] = 8'h70; sp_ten[6] = 8'h21;   // FONT.ROM[0x3cc20] (word 123408)
    sp_glyph[6] = 256'h018244442869555592929610ff10101043404058464545454850494845447c00;
    sp_ku[7] = 8'h7c; sp_ten[7] = 8'h22;   // FONT.ROM[0x45c40] (word 141856)
    sp_glyph[7] = 256'h0182824444442828281010101010103001780e082a49087f08083e0041221408;
  end
  // ==== STIMULUS ====

  task automatic fail(input [8*80-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask
  integer active_dots, sync_dots, lit_dots;
  integer lit_l, lit_r;
  reg [9:0] held_hdot;

  task automatic write_io(input [7:0] portnum, input [7:0] data);
    begin
      @(negedge clk_sys);
      io_addr = portnum;
      io_din = data;
      io_wr = 1;
      @(negedge clk_sys);
      io_wr = 0;
    end
  endtask

  task automatic read_io(input [7:0] portnum, output [7:0] data);
    begin
      @(negedge clk_sys);
      io_addr = portnum;
      #1 data = io_dout;
      @(negedge clk_sys);
    end
  endtask

  task automatic write_tram(input [13:0] addr, input [7:0] data);
    begin
      @(negedge clk_sys);
      tram_cpu_addr = addr;
      tram_cpu_din = data;
      tram_cpu_we = 1;
      @(negedge clk_sys);
      tram_cpu_we = 0;
    end
  endtask

  task automatic write_font(input [17:0] addr, input [15:0] data);
    begin
      @(negedge clk_sys);
      font_ld_addr = addr;
      font_ld_data = data;
      font_ld_we = 1;
      @(negedge clk_sys);
      font_ld_we = 0;
    end
  endtask

  // The pack's FONT.ROM copy as this bench's SDRAM: 32-bit dwords by byte address. The walker
  // and the CPU block fetch glyphs from here over the fmem handshake, exactly as
  // pc9821_memory_subsystem's requester does from the pack.
  reg [31:0] fmem [0:131071];
  reg        fmem_busy = 0;
  reg  [2:0] fmem_idx  = 0;
  reg [18:0] fmem_base = 0;
  reg        fmem_go   = 0;
  always @(posedge clk_sys) begin
    font_word_valid <= 1'b0;
    if (!fmem_busy) begin
      if (font_req && !fmem_go) begin
        fmem_go   <= 1'b1;
        fmem_base <= font_req_addr;
        fmem_idx  <= 3'd0;
      end else if (fmem_go) begin
        fmem_go   <= 1'b0;
        fmem_busy <= 1'b1;
      end
    end else begin
      font_word_valid <= 1'b1;
      font_word_data  <= fmem[{fmem_base[18:2]} + fmem_idx];
      fmem_idx        <= fmem_idx + 3'd1;
      if (fmem_idx == 3'd7) fmem_busy <= 1'b0;
    end
  end

  // Load one glyph into the SDRAM model at its FONT.ROM byte address.
  task automatic load_jis_glyph(input [7:0] ku, input [7:0] ten, input [255:0] g);
    integer k;
    reg [18:0] base;
    begin
      base = 19'h1800 + (ku - 8'h21) * 19'hC00 + (ten - 8'h20) * 19'h20;
      for (k = 0; k < 8; k = k + 1)
        fmem[base[18:2] + k[18:0]] =
          {g[(k*4+3)*8 +: 8], g[(k*4+2)*8 +: 8], g[(k*4+1)*8 +: 8], g[(k*4+0)*8 +: 8]};
    end
  endtask

  // Fill the whole text plane: even cells take the two-byte JIS code (low byte = ku - 0x20,
  // high byte = ten) and odd cells take `second` (0x0020 is what a cleared cell holds). A
  // visible attribute on both. Filling the plane is what removes any dependence on where the
  // scanout starts.
  task automatic fill_jis_plane(input [7:0] ku, input [7:0] ten,
                                input [7:0] second_lo, input [7:0] second_hi);
    integer k;
    begin
      for (k = 0; k < 16'h1000; k = k + 1) begin
        if (!k[0]) begin
          write_tram(k[13:0]*14'd2,           ku - 8'h20);
          write_tram(k[13:0]*14'd2 + 14'd1,   ten);
        end else begin
          write_tram(k[13:0]*14'd2,           second_lo);
          write_tram(k[13:0]*14'd2 + 14'd1,   second_hi);
        end
        write_tram(14'h2000 + k[13:0]*14'd2, 8'hE1);
      end
    end
  endtask

  // Sample the 16 dots of cells 0 and 1 on scanline `raster` into two bytes. The dot at hdot i
  // is glyph bit 7-(i&7) (the RTL renders r_font[~adot[2:0]]), so cell 0's byte is the glyph byte
  // MSB-first.
  task automatic sample_pair(input [3:0] raster, output [7:0] obs_a, output [7:0] obs_b);
    integer k;
    begin
      while (dut.u_crtc.vline != {6'd0, raster}) @(negedge clk_sys);
      obs_a = 8'h00;
      obs_b = 8'h00;
      for (k = 0; k < 16; k = k + 1) begin
        while (dut.u_crtc.hdot != k[9:0]) @(negedge clk_sys);
        if (k < 8) obs_a[7-k]   = (r_out != 0 || g_out != 0 || b_out != 0);
        else       obs_b[7-(k-8)] = (r_out != 0 || g_out != 0 || b_out != 0);
      end
    end
  endtask

  // The same sampler on an arbitrary text row: vline == {row, raster}. sample_pair above is
  // this with the row fixed at 0.
  task automatic sample_pair_row(input [4:0] row, input [3:0] raster,
                                 output [7:0] obs_a, output [7:0] obs_b);
    integer k;
    begin
      while (dut.u_crtc.vline != {row, raster}) @(negedge clk_sys);
      obs_a = 8'h00;
      obs_b = 8'h00;
      for (k = 0; k < 16; k = k + 1) begin
        while (dut.u_crtc.hdot != k[9:0]) @(negedge clk_sys);
        if (k < 8) obs_a[7-k]   = (r_out != 0 || g_out != 0 || b_out != 0);
        else       obs_b[7-(k-8)] = (r_out != 0 || g_out != 0 || b_out != 0);
      end
    end
  endtask

  // 40-COLUMN MODE. One character cell is 16 dots there and the cell's 8-bit glyph byte is
  // stretched two dots per bit (the RTL renders `r_font[~adot[3:1]]`), so the byte is read back
  // MSB-first from the even dots: dot 2i draws r_font[~i]. sample_pair_row above is the 80-column
  // form and would mix the two halves, which is exactly what this mode must not do.
  task automatic sample_col40_row(input [4:0] row, input [3:0] raster, output [7:0] obs);
    integer k;
    begin
      while (dut.u_crtc.vline != {row, raster}) @(negedge clk_sys);
      obs = 8'h00;
      for (k = 0; k < 8; k = k + 1) begin
        while (dut.u_crtc.hdot != (2*k)) @(negedge clk_sys);
        obs[7-k] = (r_out != 0 || g_out != 0 || b_out != 0);
      end
    end
  endtask

  // Refetch the plane with the new code before sampling it. The frame boundary is the raster's
  // own frame_end, NOT a frame_cnt change: frame_cnt is the character blink's count and advances
  // once per CSRFORM `timing` frames, so it is no longer a frame
  // counter.
  task automatic next_frame;
    begin
      while (dut.u_crtc.frame_end) @(negedge clk_sys);
      while (!dut.u_crtc.frame_end) @(negedge clk_sys);
    end
  endtask

  // NP2kai font/font.c:39 font_setchargraph, the 8x16 bank at fontrom 0x81000 (glyph byte MSB =
  // leftmost dot): row r of code c.
  function automatic [7:0] sg_ref(input [7:0] c, input [3:0] r);
    begin
      sg_ref = (c[r[3:2]] ? 8'hF0 : 8'h00) | (c[{1'b1, r[3:2]}] ? 8'h0F : 8'h00);
      if (c == 8'hF2 && r < 4'd2) sg_ref = 8'h00;   // `if (!epson)` the NEC patch
    end
  endfunction

  task automatic spin_one_frame;
    begin
      next_frame();
    end
  endtask

  // The bench's own FRAME counter, for the waits that used to be "at least N frames have passed".
  // frame_cnt cannot serve: it is the character blink's count and advances once per CSRFORM
  // `timing` frames. Counting the same edges frame_cnt did (the
  // raster's frame_end, once per frame from reset) keeps those waits at their original point.
  integer frame_ends = 0;
  always @(posedge clk_sys) if (rst_n_sys && dut.u_crtc.frame_end) frame_ends <= frame_ends + 1;
  // The CG record's power-up image (store 0x810..0x81D), captured before anything writes the
  // store. The machine-reset seed check at the end of the checks restores the record and compares
  // against THIS, which is what keeps the bench from carrying a second copy of the 14 bytes - the
  // same one-definition rule the OSD-action check inside follows.
  reg [7:0] cg_rec_powerup [0:13];
  // The DIP port mirror's expected image: bank A at store 0x50..0x5B
  // and bank B at 0x40..0x4B. Capture-rows, not this RTL's own image: bank A is
  // docs/probes/PORTS.TXT:258 (841E 7C 851E 02 861E 76 871E 3E ...), bank B the
  // firmware's factory table (BANK4@0x4818: 8f 80 80 80 80 80 ...).
  reg [7:0] mir_a [0:11];
  reg [7:0] mir_b [0:11];
  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk_sys);
    @(negedge clk_sys);
    rst_n_sys = 1;
    rst_n_vid = 1;
    for (i = 0; i < 14; i = i + 1) cg_rec_powerup[i] = dut.u_cg.u_cg_ram.ram[13'h810 + i];

    // ---- the DIP PORT MIRROR at CG store 0x40..0x5B: the POWER-UP image
    // BANK4@0xFC42D copies these 24 bytes INTO the software-DIP ports during POST (bank A
    // from 0x50..0x5B, bank B from 0x40..0x4B, through the CG window at code 0x0156), and
    // BANK4@0xFC824 re-syncs them from the ports on the repair path. SETUP's per-index
    // accessors (BANK3@0x21ED-0x2321) write each DIP byte to the port AND to this cell in
    // the same routine, and their helper (BANK3@0x2322) is what puts bank A at 0x50+index
    // and bank B at 0x40+index - the swap is firmware-encoded, so the seed must not "tidy"
    // it. On the machine the mirror IS the DIP image (the Xa7C9W cells behind qemu-pc98's
    // memsw.inc carry exactly that), so the expected bytes below are the capture rows
    // themselves. Taken HERE, before anything writes the store and before any restore
    // strobe: the restore walk seeds the mirror too, so a check placed after it could not
    // see a missing POWER-UP seed at all.
    // FAIL-FIRST: without the seed these cells are zero, so (1) reports 24 bytes off the
    // image and (2) reports every examined byte failing the ITF's own odd-parity verify -
    // the condition BANK4@0xFC7B2's repair and its SET THE SOFTWARE DIP-SWITCH screen
    // (BANK4@0xFC8DE) respond to.
    mir_a[0]  = 8'h7C; mir_a[1]  = 8'h02; mir_a[2]  = 8'h76; mir_a[3]  = 8'h3E;
    mir_a[4]  = 8'h7C; mir_a[5]  = 8'h7F; mir_a[6]  = 8'hFF; mir_a[7]  = 8'hBF;
    mir_a[8]  = 8'h7F; mir_a[9]  = 8'h7F; mir_a[10] = 8'h49; mir_a[11] = 8'h98;
    mir_b[0] = 8'h8F;
    for (i = 1; i < 12; i = i + 1) mir_b[i] = 8'h80;
    begin : mir_powerup_checks
      integer b, wrong, bad;
      // (1) The image is there at power-up, in the firmware's own bank layout.
      wrong = 0;
      for (b = 0; b < 12; b = b + 1) begin
        if (dut.u_cg.u_cg_ram.ram[13'h050 + b] !== mir_a[b]) wrong = wrong + 1;
        if (dut.u_cg.u_cg_ram.ram[13'h040 + b] !== mir_b[b]) wrong = wrong + 1;
      end
      if (wrong != 0) begin
        $display("FAIL the DIP mirror is not the machine DIP image (%0d of 24 bytes differ; bank A belongs at 0x50..0x5B, bank B at 0x40..0x4B)", wrong);
        errors = errors + 1;
      end
      // (2) The verifier's own predicate over the bytes the FC42D copy would hand the
      // ports: odd parity on bank A 0,2,3,4,7..11 and bank B 0..9, and the 0x89^0x8A XOR
      // pair odd (BANK4@0xFC6C3-0xFC726). Bank-A index 1 is excluded exactly as the verify
      // excludes it (its parity bit is presented from port 0x31 on the read), and bank B
      // 10/11 sit outside the verify's ten-iteration loop - this is the verify's own shape.
      bad = 0;
      for (b = 0; b < 12; b = b + 1) begin
        if (b != 1 && b != 5 && b != 6)
          if ((^dut.u_cg.u_cg_ram.ram[13'h050 + b]) !== 1'b1) bad = bad + 1;
        if (b < 10)
          if ((^dut.u_cg.u_cg_ram.ram[13'h040 + b]) !== 1'b1) bad = bad + 1;
      end
      if ((^(dut.u_cg.u_cg_ram.ram[13'h055] ^ dut.u_cg.u_cg_ram.ram[13'h056])) !== 1'b1)
        bad = bad + 1;
      if (bad != 0) begin
        $display("FAIL %0d DIP-mirror byte(s) fail the ITF's own odd-parity verify", bad);
        errors = errors + 1;
      end else
        $display("  DIP mirror: 24 image bytes, 0 of 20 examined fail the ITF's odd-parity verify");
    end

    // Synthetic all-on 8x16 glyph for ANK 'A'. Two raster bytes are loaded
    // per repository ROM-pack word.
    for (i = 0; i < 8; i = i + 1)
      write_font(11'h208 + i[10:0], 16'hFFFF);

    write_tram(14'h0000, 8'h41);
    write_tram(14'h0001, 8'h00);
    write_tram(14'h2000, 8'hE1);

    // BCTRL on. MODE FF1 defaults to display enabled.
    write_io(8'h62, 8'h0D);
    io_addr = 8'h68;
    #1;
    if (io_dout !== 8'h98) begin
      $display("FAIL GDC mode read %02x", io_dout);
      errors = errors + 1;
    end

    // ReC98/master.lib palette_show(): A8=index, AA=green, AC=red, AE=blue.
    write_io(8'h6A, 8'h01);
    write_io(8'hA8, 8'h03);
    write_io(8'hAA, 8'h02);
    write_io(8'hAC, 8'h04);
    write_io(8'hAE, 8'h06);
    io_addr = 8'hAA;
    #1;
    if (io_dout !== 8'h02) begin
      $display("FAIL analogue green read %02x", io_dout);
      errors = errors + 1;
    end
    io_addr = 8'hAC;
    #1;
    if (io_dout !== 8'h04) begin
      $display("FAIL analogue red read %02x", io_dout);
      errors = errors + 1;
    end
    // The analogue table itself is pc9821_gfx_palette's RAM now; what stays in
    // this module is the write decode and its read mirror. The mirror keeps the FULL
    // written bytes per channel (write 0xFF reads
    // 0xFF, not the nibble), so the entry is {B=06, R=04, G=02}. All THREE channels are
    // read back THROUGH THE PORT, which is a stronger check than the white-box peep
    // (`dut.u_crtc.pal_mirror[3]`) that the storage move had to repoint. ONE clk_sys is
    // spent first because the mirror is read through a register: the write lands in the
    // entry at its own edge and the read register picks it up at the NEXT one. The
    // white-box read was combinationally direct and hid that, which is why the peep was
    // also the weaker guard. The end-to-end write -> pixel path is pinned by
    // tb_pc9821_scanout_pipeline.
    @(negedge clk_sys);
    io_addr = 8'hAA;
    #1;
    rgb_rd[7:0] = io_dout;
    io_addr = 8'hAC;
    #1;
    rgb_rd[15:8] = io_dout;
    io_addr = 8'hAE;
    #1;
    rgb_rd[23:16] = io_dout;
    if (rgb_rd !== 24'h060402) begin
      $display("FAIL analogue RGB order {B,R,G}=%06x, expected 060402", rgb_rd);
      errors = errors + 1;
    end

    // Pixel CE must freeze all timing state.
    @(negedge clk_sys);
    pixel_ce = 0;
    held_hdot = dut.u_crtc.hdot;
    repeat (8) @(posedge clk_sys);
    if (dut.u_crtc.hdot !== held_hdot) begin
      $display("FAIL pixel CE hold %0d -> %0d", held_hdot, dut.u_crtc.hdot);
      errors = errors + 1;
    end
    @(negedge clk_sys);
    pixel_ce = 1;

    // The graphics-GDC status stub at A0 must expose the shared VSYNC and
    // empty bits used by the vendor ITF's vertical-blank wait.
    io_addr = 8'hA0;
    wait (vsync_active);
    #1;
    if (!io_dout[5] || !io_dout[2]) begin
      $display("FAIL GDC2 active status %02x", io_dout);
      errors = errors + 1;
    end
    wait (!vsync_active);
    #1;
    if (io_dout[5] || !io_dout[2]) begin
      $display("FAIL GDC2 inactive status %02x", io_dout);
      errors = errors + 1;
    end

    // Port 0x64 arms the one-shot VSYNC IRQ latch (NP2kai gdc_o64; ReC98's
    // INT 0Ah handler rearms it after the PIC EOI). Unarmed frames must
    // deliver no request; each armed frame delivers exactly one pulse.
    wait (vsync_active);
    wait (!vsync_active);
    wait (vsync_active);
    wait (!vsync_active);
    if (irq_pulses != 0) begin
      $display("FAIL unarmed VSYNC IRQ count %0d", irq_pulses);
      errors = errors + 1;
    end
    write_io(8'h64, 8'h00);
    wait (vsync_active);
    wait (!vsync_active);
    if (irq_pulses != 1) begin
      $display("FAIL armed VSYNC IRQ count %0d", irq_pulses);
      errors = errors + 1;
    end
    write_io(8'h64, 8'hFF);   // data value is ignored; any write arms
    wait (vsync_active);
    wait (!vsync_active);
    if (irq_pulses != 2) begin
      $display("FAIL rearmed VSYNC IRQ count %0d", irq_pulses);
      errors = errors + 1;
    end

    // ... and the PHASE, which the count above cannot see. The VSYNC PULSE is the sync
    // pulse: vline 407..414, i.e. VACTIVE + VFP through +VSYNC_W, 7 lines of front porch after the
    // last active line. The vblank IRQ rises ON that pulse's leading edge, so the guest's window
    // after the interrupt is 33 lines (66,462 clk_sys), not the 40 (80,560) an interrupt at the
    // top of blanking would give it. MAME's uPD7220 device drives its VSYNC output active at
    // y = vbp + al + vfp with the visible top at vbp (upd7220.cpp:347-358, :428-429), the PC-98
    // driver raises IRQ2 from that same edge (pc9801.cpp:1895 -> vrtc_irq), and the pulse's WIDTH
    // is the GDC SYNC block's `vs` field - 8 lines for the machine's power-on defsyncm24, which the
    // on-card 2M-sample histogram measures directly: bit 5 high in 36 385 of 2 097 152 samples =
    // 1.735 % = 8 of 440 lines (docs/probes/GDC.TXT; the "12 lines / 2.8 %" this comment used to
    // cite divided the same count by 1 310 720 instead of the capture's own always-set 2^21). That
    // also refutes NP2kai's 40-line blank-wide status.
    if (pulse_vline !== 10'd407 || irq_vline < 10'd407 || irq_vline > 10'd408) begin
      $display("FAIL VSYNC phase: pulse rose on vline %0d (want 407), IRQ on vline %0d (want 407-408)",
               pulse_vline, irq_vline);
      errors = errors + 1;
    end else
      $display("  vsync phase: pulse vline=%0d, armed IRQ vline=%0d (the sync pulse's rising edge)",
               pulse_vline, irq_vline);

    // The slave GDC's display latch on 0xA2 -- the compositor's display enable.
    // NP2kai drives one display flag per chip from one command space: io/gdc.c:268
    // picks gdcs.textdisp for the master and gdcs.grphdisp for the slave, and
    // io/gdc.c:298-310 sets or clears whichever it picked from the same command
    // bytes (io/gdc_cmd.h: CMD_START=0x0d, CMD_STOP=0x0c, CMD_STOP_=0x05,
    // CMD_START_=0x6b, CMD_SYNC_ON=0x0f, CMD_SYNC_OFF=0x0e, all with no parameter
    // bytes). Reset must leave it OFF, so a guest that never issues START keeps
    // the black-where-graphics-would-be picture the tied-low constant gave.
    if (gfx_disp !== 1'b0) fail("graphics display was ON at reset");
    write_io(8'hA2, 8'h0D);
    if (gfx_disp !== 1'b1) fail("GDC2 0x0D (START) did not enable graphics display");
    write_io(8'hA2, 8'h0C);
    if (gfx_disp !== 1'b0) fail("GDC2 0x0C (STOP) did not disable graphics display");
    write_io(8'hA2, 8'h6B);
    if (gfx_disp !== 1'b1) fail("GDC2 0x6B (BCTRL on) did not enable graphics display");
    write_io(8'hA2, 8'h05);
    if (gfx_disp !== 1'b0) fail("GDC2 0x05 (BCTRL off) did not disable graphics display");
    write_io(8'hA2, 8'h0F);
    if (gfx_disp !== 1'b1) fail("GDC2 0x0F (SYNC on) did not enable graphics display");
    write_io(8'hA2, 8'h0E);
    if (gfx_disp !== 1'b0) fail("GDC2 0x0E (SYNC off) did not disable graphics display");
    // SCROLL shares this port and must leave the display alone: it is a
    // different command, and conflating the two would blank the screen every
    // time a game scrolled.
    write_io(8'hA2, 8'h70);
    if (gfx_disp !== 1'b0) fail("GDC2 SCROLL 0x70 changed the display enable");
    write_io(8'hA2, 8'h0D);   // leave it enabled: a START is what the BIOS does
    if (gfx_disp !== 1'b1) fail("GDC2 START did not stay enabled across a SCROLL");
    write_io(8'hA2, 8'h70);
    if (gfx_disp !== 1'b1) fail("GDC2 SCROLL 0x70 cleared an enabled display");
    write_io(8'hA2, 8'h0C);   // and restore display-off for the cases below
    if (gfx_disp !== 1'b0) fail("GDC2 STOP did not clear the display again");

    // Allow one frame boundary to transfer CPU-side display registers.
    wait (frame_ends >= 1);
    wait (dut.u_crtc.hdot == 0 && dut.u_crtc.vline == 0);

    active_dots = 0;
    sync_dots = 0;
    for (i = 0; i < 848; i = i + 1) begin
      @(negedge clk_sys);
      if (de_out) active_dots = active_dots + 1;
      if (!hs_out) sync_dots = sync_dots + 1;
    end
    // hsync = 8 x (hs + 1) dots, the uPD7220's field map (MAME upd7220.cpp:1243 `m_hs = (m_pr[3] & 0x1f) + 1`)
    if (active_dots != 640 || sync_dots != 64) begin
      $display("FAIL line geometry active=%0d hsync=%0d", active_dots, sync_dots);
      errors = errors + 1;
    end

    // The first cell after initial reset is intentionally blank. By the next
    // frame the wrapped prefetch has populated its render registers.
    wait (frame_ends >= 2);
    wait (dut.u_crtc.hdot == 0 && dut.u_crtc.vline == 0);
    lit_dots = 0;
    for (i = 0; i < 8; i = i + 1) begin
      @(negedge clk_sys);
      if (r_out != 0 || g_out != 0 || b_out != 0) lit_dots = lit_dots + 1;
    end
    if (!disp_on || lit_dots != 8) begin
      $display("FAIL text pixel display=%b lit=%0d rgb=%02x%02x%02x",
               disp_on, lit_dots, r_out, g_out, b_out);
      errors = errors + 1;
    end

    // ---- CG window -------------------------------------------------------
    // 0xA1 sets the code high byte, 0xA3 the low byte, 0xA5 the glyph row (bit
    // 5 inverted selects a kanji cell's other half), 0xA9 reads/writes the
    // pattern byte. The bench fills the glyph for code 0x41 with 0xFFFF.
    write_io(8'hA1, 8'h00);
    write_io(8'hA3, 8'h41);
    write_io(8'hA5, 8'h00);        // row 0
    read_io(8'hA9, value);
    if (value !== 8'hFF) fail("CG window ANK read, glyph 'A' row 0");
    write_io(8'hA5, 8'h0F);        // row 15
    read_io(8'hA9, value);
    if (value !== 8'hFF) fail("CG window ANK read, row 15");

    // Row bit 4 set means "not an ANK access" and must read back blank rather
    // than as some other row's pattern.
    write_io(8'hA5, 8'h10);
    read_io(8'hA9, value);
    if (value !== 8'h00) fail("CG window ANK read with row bit 4 set");

    // The writable user CG area is selected by the code's LOW byte being 0x56 or
    // 0x57 (NP2kai cgrom_oa9 gates the write with 0x007E). The area is page
    // indexed -- the reference addresses it as ((code & 0x7F7F) << 4) + lr + row
    // -- so the code's HIGH byte picks one of 128 pages of 64 bytes, 8 KiB.
    // Page 0 is not reachable through a 0xA9 *read*: a one-byte code takes the
    // ANK branch, so a non-zero page is needed for the write to be observable.
    write_io(8'hA1, 8'h10);        // code high: page 0x10
    write_io(8'hA3, 8'h56);        // code low = 0x56 -> user area, writable
    write_io(8'hA5, 8'h03);        // row 3
    write_io(8'hA9, 8'h5A);
    read_io(8'hA9, value);
    if (value !== 8'h5A) fail("user CG RAM write/read");
    if (dut.u_cg.cg_code !== 16'h1056) fail("CG code register packing (A1 high, A3 low)");

    // The other half of the cell is a different location, and switching back
    // must still return what was written.
    write_io(8'hA5, 8'h23);        // row 3, bit 5 set -> other half
    read_io(8'hA9, value);
    if (value === 8'h5A) fail("CG RAM left/right half aliased");
    write_io(8'hA5, 8'h03);
    read_io(8'hA9, value);
    if (value !== 8'h5A) fail("CG RAM lost the written byte after a half switch");

    // Pages must be *distinct* storage. A 64-byte array (which this RTL once
    // had, and which this bench used to encode) aliased all 128 pages onto the
    // same cells, which silently corrupted the firmware's own memory-switch
    // table -- it writes 31 different pages.
    write_io(8'hA1, 8'h11);        // page 0x11, same code low byte and row
    write_io(8'hA3, 8'h56);
    write_io(8'hA5, 8'h03);
    read_io(8'hA9, value);
    if (value === 8'h5A) fail("user CG pages alias (page 0x11 sees page 0x10's byte)");
    write_io(8'hA9, 8'h3C);
    read_io(8'hA9, value);
    if (value !== 8'h3C) fail("user CG page 0x11 write/read");
    write_io(8'hA1, 8'h10);        // back to page 0x10
    write_io(8'hA3, 8'h56);
    write_io(8'hA5, 8'h03);
    read_io(8'hA9, value);
    if (value !== 8'h5A) fail("page 0x10 lost its byte after writing page 0x11");

    // A one-byte code 0x56 is the *ANK* branch on a read even though it is what
    // the write gate accepts, so it must not return the user CG byte.
    write_io(8'hA1, 8'h00);
    write_io(8'hA3, 8'h56);
    write_io(8'hA5, 8'h00);
    read_io(8'hA9, value);
    if (value === 8'h5A) fail("a one-byte code 0x0056 read back user CG data");

    // Negative case for the 0xA9 read gate: only the two-byte codes
    // whose LOW byte is 0x56/0x57 are this core's user-CG store. Write a byte
    // to page 0x29 (code 0x2956), then read the *different* code 0x2941 -- the
    // same page, low byte 0x41 -- and require it is not that byte. Before P2
    // every two-byte code read cg_ram and this returned 0xA5.
    write_io(8'hA1, 8'h29);
    write_io(8'hA3, 8'h56);
    write_io(8'hA5, 8'h03);
    write_io(8'hA9, 8'hA5);
    write_io(8'hA3, 8'h41);
    write_io(8'hA5, 8'h03);
    read_io(8'hA9, value);
    if (value === 8'hA5) fail("0xA9 read applied the user-CG gate to a non-gaiji code");

    // ---- the machine-reset seed restores the CG record (the walk) ---------
    // The record the ITF's 0xFC681 marker/sum check reads is the 14 bytes at
    // CG store 0x810..0x81D (code 0x2056, lr = 1, rows 0..0xD). THIS BENCH DRIVES cfg_seed_en = 0,
    // so what is asserted here is the RAW store behind the static configuration view
    // (the view itself is tb_pc9821_cg_read_path's): a guest write moves the RAM, and
    // the machine-reset seed's restore walk - now the walk's ONLY source, there being no
    // OSD `Reset DIPs`/`Zero DIPs` action -
    // writes the image back. One byte is also read through port 0xA9 to prove the path
    // a guest uses sees the same value.
    begin
      reg [7:0] rec_expected [0:13];
      integer r, wrong;
      for (r = 0; r < 14; r = r + 1)
        rec_expected[r] = dut.u_cg.u_cg_ram.ram[13'h810 + r];
      // Precondition: the record is the dump-sourced image, so a passing
      // restore assertion cannot be the store never having been set.
      if (rec_expected[8] !== 8'hAA || rec_expected[9] !== 8'h55)
        fail("the power-up CG record is not the dump image (rows 8/9 != AA/55)");
      // Move it: a guest write through 0xA9 into the record's row 8 and 0.
      write_io(8'hA1, 8'h20);
      write_io(8'hA3, 8'h56);
      write_io(8'hA5, 8'h08);        // row 8 = store 0x818
      write_io(8'hA9, 8'h3C);
      write_io(8'hA5, 8'h00);        // row 0 = store 0x810
      write_io(8'hA9, 8'h77);
      if (dut.u_cg.u_cg_ram.ram[13'h818] === rec_expected[8])
        fail("the CG record never moved: the restore test is vacuous");

      // The machine-reset seed: the whole 14-byte record is the model's image again.
      cg_record_restore = 1'b1;
      repeat (2) @(posedge clk_sys);
      cg_record_restore = 1'b0;
      repeat (40) @(posedge clk_sys);
      wrong = 0;
      for (r = 0; r < 14; r = r + 1)
        if (dut.u_cg.u_cg_ram.ram[13'h810 + r] !== rec_expected[r]) wrong = wrong + 1;
      if (wrong != 0) begin
        $display("FAIL the reset seed did not restore the CG record (%0d of 14 bytes differ)", wrong);
        errors = errors + 1;
      end
      write_io(8'hA5, 8'h08);
      read_io(8'hA9, value);
      if (value !== 8'hAA)
        fail("the reset seed: the CG record's 0xA9 read lost the marker high byte");
    end

    // ---- the DIP port mirror is re-seeded by the same restore walk ----
    // The power-up half of this contract is asserted at the top of the checks (before any
    // store write); what is pinned here is that the ONE restore walk covers the mirror too,
    // record first: after 16 clk_sys the record must already be whole while the mirror's 24
    // bytes are still being written, and by 40 the walk is over and both stores are back.
    begin
      integer b, wrong;
      write_io(8'hA1, 8'h01);
      write_io(8'hA3, 8'h56);
      write_io(8'hA5, 8'h01);        // bank A row 1 = store 0x51
      write_io(8'hA9, 8'h00);
      write_io(8'hA5, 8'h20);        // bank B row 0 = store 0x40
      write_io(8'hA9, 8'h00);
      if (dut.u_cg.u_cg_ram.ram[13'h051] === mir_a[1] &&
          dut.u_cg.u_cg_ram.ram[13'h040] === mir_b[0])
        fail("the DIP-mirror restore check is vacuous: the guest write never moved the mirror");
      cg_record_restore = 1'b1;
      repeat (2) @(posedge clk_sys);
      cg_record_restore = 1'b0;
      repeat (14) @(posedge clk_sys);
      wrong = 0;
      for (b = 0; b < 14; b = b + 1)
        if (dut.u_cg.u_cg_ram.ram[13'h810 + b] !== cg_rec_powerup[b]) wrong = wrong + 1;
      if (wrong != 0) begin
        $display("FAIL the restore walk wrote the mirror before the record (%0d of 14 record bytes differ 16 clk_sys in)", wrong);
        errors = errors + 1;
      end
      repeat (24) @(posedge clk_sys);
      if (dut.u_cg.cg_rec_busy)
        fail("the restore walk was still running 40 clk_sys after the strobe");
      wrong = 0;
      for (b = 0; b < 12; b = b + 1) begin
        if (dut.u_cg.u_cg_ram.ram[13'h050 + b] !== mir_a[b]) wrong = wrong + 1;
        if (dut.u_cg.u_cg_ram.ram[13'h040 + b] !== mir_b[b]) wrong = wrong + 1;
      end
      if (wrong != 0) begin
        $display("FAIL the restore walk did not restore the DIP mirror (%0d of 24 bytes differ)", wrong);
        errors = errors + 1;
      end
    end

    // ---- PRAM screen parameter writes ------------------------
    // Command 0x70 programs screen 0's {sad_lo, sad_hi, len_lo, len_hi} over four parameter
    // bytes; only the first two reach the scanout (pram_scr[0]/[1]), so only they are kept.
    // Screens 1-3 (0x74/0x78/0x7C) and every length byte are accepted and dropped - the
    // GDC's PRAM is write-only, so those cells have no reader. The command
    // must still consume its four bytes, which the 0x70 write later in this section (the
    // 0x1000-word display-start case) proves.
    write_io(8'h62, 8'h70);
    write_io(8'h60, 8'h11);
    write_io(8'h60, 8'h22);
    write_io(8'h60, 8'h33);
    write_io(8'h60, 8'h44);
    if (dut.u_crtc.pram_scr[0] !== 8'h11 || dut.u_crtc.pram_scr[1] !== 8'h22) begin
      $display("FAIL: pram_scr = %02x %02x, expected 11 22", dut.u_crtc.pram_scr[0], dut.u_crtc.pram_scr[1]);
      errors = errors + 1;
    end

    write_io(8'h62, 8'h74);
    write_io(8'h60, 8'h55);
    write_io(8'h60, 8'h66);
    write_io(8'h60, 8'h77);
    write_io(8'h60, 8'h88);

    write_io(8'h62, 8'h78);
    write_io(8'h60, 8'h99);
    write_io(8'h60, 8'hAA);
    write_io(8'h60, 8'hBB);
    write_io(8'h60, 8'hCC);

    write_io(8'h62, 8'h7C);
    write_io(8'h60, 8'hDD);
    write_io(8'h60, 8'hEE);
    write_io(8'h60, 8'hFF);
    write_io(8'h60, 8'h12);

    // A screen-1/2/3 command (and 0x70's own length bytes) must leave screen 0 alone.
    if (dut.u_crtc.pram_scr[0] !== 8'h11 || dut.u_crtc.pram_scr[1] !== 8'h22)
      fail("a screen-1/2/3 PRAM command disturbed screen 0");

    // ---- GRCG mode/tile read-back ------------------------------
    // The mode and tile registers moved out of this module into pc9821_grcg,
    // which owns their decode and the GVRAM write path they drive (see that
    // module's header and tb_pc9821_grcg.sv, which asserts the four-plane fill).
    // What this boundary answers is the OPEN-BUS byte: 0x7C is WRITE-ONLY on the
    // machine - probe2 /RDBACK wrote 0x5A there and read 0xFF anyway
    // (`port=007C before=FF wrote=5A after=FF back=FF`, docs/probes/RDBACK.TXT:152),
    // so the port reads 0xFF and NOT the live GRCG mode register this bench used to
    // assert (NP2kai crtc_i7c - the capture outranks it).
    // 0x7E has no read handler anywhere and stays 0xFF.
    // The writes are kept because 0x7C/0x7E are still decoded as the video
    // device's ports at this boundary, and the reads confirm this module does
    // not answer them from a local latch.
    write_io(8'h7C, 8'hC0);
    write_io(8'h7E, 8'hB1);
    write_io(8'h7E, 8'hB2);
    write_io(8'h7E, 8'hB3);
    write_io(8'h7E, 8'hB4);
    io_addr = 8'h7C;
    #1;
    if (io_dout !== 8'hFF) fail("0x7C is write-only on the machine and must read open bus 0xFF");
    io_addr = 8'h7E;
    #1;
    if (io_dout !== 8'hFF) fail("0x7E is write-only and must read 0xFF");

    // Graphics page registers (ReC98 page_show/page_access). 0xA6 drives the
    // GVRAM window in the memory map, so it is exported; 0xA4 selects the page
    // the display scans out. Both read back the selected page.
    write_io(8'hA6, 8'h01);
    read_io(8'hA6, value);
    if (value !== 8'h01 || !gfx_access_page) fail("graphics access page register");
    write_io(8'hA4, 8'h01);
    read_io(8'hA4, value);
    if (value !== 8'h01) fail("graphics display page register");
    write_io(8'hA6, 8'h00);
    read_io(8'hA6, value);
    if (value !== 8'h00 || gfx_access_page) fail("graphics access page did not clear");

    // A code outside the user area must not be writable: the ANK glyph for 'A'
    // has to survive a write attempt unchanged.
    write_io(8'hA1, 8'h00);
    write_io(8'hA3, 8'h41);
    write_io(8'hA5, 8'h00);
    write_io(8'hA9, 8'h5A);
    read_io(8'hA9, value);
    if (value !== 8'hFF) fail("CG window write outside the user area was not ignored");

    // ---- gaiji (user-CG) scanout -------------------------------
    // A two-byte code whose LOW byte is 0x56/0x57 renders from cg_ram, with a
    // positional half: the first cell of a pair takes +0 (left), the second
    // +0x800 (right), and a non-gaiji cell clears it. The 0xA5 bit-5 register
    // is I/O-only and must not drive the scanout, so the cg_lr register is left
    // at 1 (A5 bit 5 clear) while the *left* half must still show.
    // Define the whole used TRAM region as non-gaiji code 0x0020 first: an
    // uninitialised cell feeds an x into the fetch latch, and f_half is a
    // fetch-side register, so one x cell would poison the positional half for
    // the next gaiji cell (simulation only; real TRAM always holds a value).
    for (i = 0; i < 2000; i = i + 1) begin
      write_tram(i[13:0]*14'd2, 8'h20);
      write_tram(i[13:0]*14'd2 + 14'd1, 8'h00);
      write_tram(14'h2000 + i[13:0]*14'd2, 8'h00);
    end
    write_tram(14'h0000, 8'h56);
    write_tram(14'h0001, 8'h10);
    write_tram(14'h2000, 8'hE1);
    write_tram(14'h0002, 8'h56);
    write_tram(14'h0003, 8'h10);
    write_tram(14'h2002, 8'hE1);
    write_io(8'hA1, 8'h10);
    write_io(8'hA3, 8'h56);
    // cg_lr is 0xA5 bit 5 *inverted*, so A5 bit5 clear leaves cg_lr = 1:
    // write the right half (dark) with bit5 clear and the left half (all dots
    // on) with bit5 set.
    for (i = 0; i < 16; i = i + 1) begin
      write_io(8'hA5, i[4:0]);          // cg_lr = 1: right half, all dots off
      write_io(8'hA9, 8'h00);
    end
    for (i = 0; i < 16; i = i + 1) begin
      write_io(8'hA5, 8'h20 | i[4:0]);  // cg_lr = 0: left half, all dots on
      write_io(8'hA9, 8'hFF);
    end
    write_io(8'hA5, 8'h00);             // leave the cg_lr register at 1

    // Let the wrapped prefetch load the new cells, then sample cells 0 and 1.
    wait (frame_ends >= 3);
    wait (dut.u_crtc.hdot == 0 && dut.u_crtc.vline == 0);
    lit_l = 0;
    lit_r = 0;
    for (i = 0; i < 16; i = i + 1) begin
      @(negedge clk_sys);
      if (r_out != 0 || g_out != 0 || b_out != 0) begin
        if (i < 8) lit_l = lit_l + 1;
        else lit_r = lit_r + 1;
      end
    end
    if (lit_l != 8) fail("gaiji left half did not render from cg_ram");
    if (lit_r != 0) fail("gaiji second cell used the wrong positional half");

    // ---- the JIS kanji pair, from FONT.ROM (LEVEL 1) ----
    // JIS 0x3021: the TRAM LOW byte is ku - 0x20 (so 0x10 means row 0x30) and the HIGH byte is
    // ten itself. The RTL's address is 0x1800 + (ku-0x21)*0xC00 + (ten-0x20)*0x20, so this
    // glyph is FONT.ROM[0xCC20]. The font store holds FONT.ROM[0x800:0x46800] verbatim, two
    // bytes per 16-bit word (low byte = the even dump byte), so its store word is
    // (0xCC20 - 0x800)/2 = 25104. The words below are the dump's own bytes
    // (bios/xe10/FONT.ROM[0xCC20..0xCC3F]) verbatim, so this asserts the machine's data and not
    // a model of it. Cell 1 carries 0x0000 in TRAM on purpose: it is the pair's right half and
    // its own code must be ignored, exactly as NP2kai's kanji2nd arm does.
    // The whole text plane takes the code, so the check does not depend on where the earlier
    // checks left the screen start address (CSRW): every even cell is this kanji's left half
    // and every odd cell its right half, whichever word the scanout starts from. The row-15
    // bytes are 0x7F (left, 7 dots) and 0xFF (right, 8 dots); a blank cell gives 0 and 0, and
    // whichever half the line starts on, the two cells are those two bytes in some order - so
    // the check compares the pair of dot counts as a set.
    for (i = 0; i < 16'h1000; i = i + 1) begin
      write_tram(i[13:0] * 2 + 14'd0, 8'h10);          // ku = code[6:0] + 0x20 = 0x30
      write_tram(i[13:0] * 2 + 14'd1, 8'h21);          // ten = code[14:8] = 0x21
      write_tram(14'h2000 + i[13:0] * 2, 8'hE1);       // attribute: visible, colour 7
    end
    load_jis_glyph(8'h30, 8'h21, sp_glyph[3]);   // FONT.ROM[0xCC20], the dump's own 32 bytes

    // Sample raster row 15 of cells 0 and 1, one dot per hdot. The loop waits for hdot == i, so
    // i = 0..7 are cell 0's eight dots and i = 8..15 cell 1's (the render register is latched at
    // the end of the previous cell and holds this cell's glyph, so the sample is cell-aligned).
    wait (frame_ends >= 4);
    while (dut.u_crtc.vline != 9'd15) @(negedge clk_sys);
    lit_l = 0;
    lit_r = 0;
    for (i = 0; i < 16; i = i + 1) begin
      while (dut.u_crtc.hdot != i[9:0]) @(negedge clk_sys);
      if (r_out != 0 || g_out != 0 || b_out != 0) begin
        if (i < 8) lit_l = lit_l + 1;
        else       lit_r = lit_r + 1;
      end
    end
    $display("  kanji scan (level-1 ku 0x30): cell0=%0d cell1=%0d (want 7 and 8, either order)", lit_l, lit_r);
    if (!((lit_l == 7 && lit_r == 8) || (lit_l == 8 && lit_r == 7)))
      fail("JIS kanji halves did not render from the font store as bytes 0x7F and 0xFF");

    // ---- the JIS kanji pair, from FONT.ROM (LEVEL 2) ----
    // JIS 0x502C is ku 0x50, the FIRST LEVEL-2 ROW (level 1 is ku 0x30..0x4F). It is exactly
    // the class the old level-1-only store could not draw, so this is the check that the WHOLE
    // FONT.ROM reached the scanout: the glyph is FONT.ROM[0x24D80] and its store word is
    // (0x24D80 - 0x800)/2 = 74432. Its row-15 bytes are 0x5A (one half, 4 dots) and 0xDE (the
    // other, 6 dots), again the dump's own bytes verbatim.
    for (i = 0; i < 16'h1000; i = i + 1) begin
      write_tram(i[13:0] * 2 + 14'd0, 8'h30);          // ku = code[6:0] + 0x20 = 0x50
      write_tram(i[13:0] * 2 + 14'd1, 8'h2C);          // ten = code[14:8] = 0x2C
      write_tram(14'h2000 + i[13:0] * 2, 8'hE1);       // attribute: visible, colour 7
    end
    load_jis_glyph(8'h50, 8'h2C,
        256'hDE51_5151_5150_5050_D010_1010_5090_1090_5A44_4A5F_405F_5148_7F0A_013F_4224_3E01);

    // A frame boundary re-fetches the whole plane with the level-2 code before sampling.
    next_frame();
    while (dut.u_crtc.vline != 9'd15) @(negedge clk_sys);
    lit_l = 0;
    lit_r = 0;
    for (i = 0; i < 16; i = i + 1) begin
      while (dut.u_crtc.hdot != i[9:0]) @(negedge clk_sys);
      if (r_out != 0 || g_out != 0 || b_out != 0) begin
        if (i < 8) lit_l = lit_l + 1;
        else       lit_r = lit_r + 1;
      end
    end
    $display("  kanji scan (level-2 ku 0x50): cell0=%0d cell1=%0d (want 4 and 6, either order)", lit_l, lit_r);
    if (!((lit_l == 4 && lit_r == 6) || (lit_l == 6 && lit_r == 4)))
      fail("JIS level-2 halves did not render (full FONT.ROM not in the store?)");

    // ---- the JIS SPREAD: every raster of a glyph against the dump ----
    // Four glyphs only pinned four addresses; this drops the row/column arithmetic straight
    // into the dump. For each sample the store is loaded from the dump's bytes at the word the
    // 0x1800 + (ku-0x21)*0xC00 + (ten-0x20)*0x20 address implies, the text plane carries the
    // code, and then cell 0 must render the glyph's LEFT byte and cell 1 its RIGHT byte for every
    // one of the 16 rasters. A wrong row stride (0xBC0), a wrong row index (ku instead of
    // ku-0x21), a swapped row/column or a swapped half all land the fetch on another glyph and
    // fail here.
    // Put the display start back to 0 first: the PRAM section left screen 0's start word at
    // 0x2211 (the four parameter bytes it wrote), so the scanout was reading the plane from an
    // odd word. A uniform plane cannot see that; the spread and the pair check below can.
    write_io(8'h62, 8'h70);
    write_io(8'h60, 8'h00);
    write_io(8'h60, 8'h00);
    write_io(8'h60, 8'h00);
    write_io(8'h60, 8'h00);
    spin_one_frame;
    spin_one_frame;
    if ({dut.u_crtc.v_sad_hi, dut.u_crtc.v_sad_lo} !== 16'h0000)
      fail("the display start word did not return to 0");

    begin : check_spread
      reg [7:0] obs_a, obs_b;
      integer s, r, wrong;
      wrong = 0;
      for (s = 0; s < NSPREAD; s = s + 1) begin
        fill_jis_plane(sp_ku[s], sp_ten[s], sp_ku[s] - 8'h20, sp_ten[s]);
        load_jis_glyph(sp_ku[s], sp_ten[s], sp_glyph[s]);
        spin_one_frame;
        for (r = 0; r < 16; r = r + 1) begin
          sample_pair(r[3:0], obs_a, obs_b);
          if (obs_a !== sp_glyph[s][r*8 +: 8] || obs_b !== sp_glyph[s][(16+r)*8 +: 8]) begin
            $display("FAIL: JIS ku %02x ten %02x raster %0d: cell0=%02x cell1=%02x, dump halves %02x/%02x",
                     sp_ku[s], sp_ten[s], r, obs_a, obs_b,
                     sp_glyph[s][r*8 +: 8], sp_glyph[s][(16+r)*8 +: 8]);
            wrong = wrong + 1;
          end
        end
      end
      errors = errors + wrong;
      if (wrong != 0)
        fail("the JIS spread did not match FONT.ROM glyph for glyph");
      else
        $display("  JIS spread: %0d glyphs x 16 rasters matched the dump", NSPREAD);
    end

    // ---- the pair's SECOND cell carries no code of its own ----
    // The machine writes the 2-byte code to the first cell only: the ITF's own TEXTDISP.X86
    // (textoutcsk) stores the word with `stosw` and then does `inc di / inc di` past the second
    // cell, so that cell keeps the cleared 0x0020. NP2kai's maketext.c (`if (kanji2nd) bitmap[x]
    // = lastbitp + 0x800`) and QEMU's pc98-vga.c (`if (kanji2nd) offset = last + 0x800`) draw the
    // right half without looking at that cell's code. On a real screen that cell is how every
    // kanji pair is written, so both halves must still come from the pair's glyph.
    begin : check_right_cell
      reg [7:0] obs_a, obs_b;
      reg [255:0] g;
      integer s, wrong;
      // 0x30/0x21 (the kanji JIS 0x3021) with the cleared 0x0020 in every second cell.
      g = sp_glyph[3];
      fill_jis_plane(8'h30, 8'h21, 8'h20, 8'h00);
      load_jis_glyph(8'h30, 8'h21, g);
      spin_one_frame;
      wrong = 0;
      for (s = 0; s < 16; s = s + 1) begin
        sample_pair(s[3:0], obs_a, obs_b);
        if (!((obs_a === g[s*8 +: 8] && obs_b === g[(16+s)*8 +: 8]) ||
              (obs_a === g[(16+s)*8 +: 8] && obs_b === g[s*8 +: 8]))) begin
          $display("FAIL: second cell 0x0020, ku 0x30 raster %0d: cell0=%02x cell1=%02x, dump halves %02x/%02x",
                   s, obs_a, obs_b, g[s*8 +: 8], g[(16+s)*8 +: 8]);
          wrong = wrong + 1;
        end
      end
      if (wrong != 0)
        fail("a JIS pair's right half did not come from the pair's glyph");
    end

    // ---- the ver0.78 half-width rows (ku 0x29-0x2B) draw ONE cell ----
    // NP2kai's maketext.c:280-296 gives every two-byte cell `bitmap[x] = (kc & 0x7f7f) << 4`
    // - the grid slot BASE - and sets kanji2nd for every non-gaiji code EXCEPT the ver0.78
    // rows kc 0x09-0x0B (:292-294), so those cells draw the slot's LEFT half alone in one
    // cell and leave the next cell to its own code: the half-width glyphs of the NEC
    // extension rows. The first case is the machine's own bytes: ku 0x29 ten 0x41 is
    // FONT.ROM[0x7C20], whose left half is the 8x16 'A' and whose right half is empty
    // (bios/xe10/FONT.ROM verbatim, byte 0 in bits [7:0]). FAIL-FIRST: the pre-fix scanout
    // draws nothing for these rows (jis_ok excluded them), so every non-empty raster fails.
    begin : check_ver078_halfwidth
      reg [7:0] obs_a, obs_b;
      reg [255:0] g;
      integer s, wrong;
      // FONT.ROM[0x7C20..0x7C3F] verbatim: 'A' rows in the left 16 bytes, empty right.
      g = 256'h00000000000000000000000000000000_000042424242423c2424242424181800;
      fill_jis_plane(8'h29, 8'h41, 8'h20, 8'h00);   // even cells code 0x4109, odd cells 0x0020
      load_jis_glyph(8'h29, 8'h41, g);
      spin_one_frame;
      wrong = 0;
      for (s = 0; s < 16; s = s + 1) begin
        sample_pair(s[3:0], obs_a, obs_b);
        if (obs_a !== g[s*8 +: 8]) begin
          $display("FAIL: ver0.78 code 0x4109 raster %0d: cell0=%02x, the slot's left byte is %02x",
                   s, obs_a, g[s*8 +: 8]);
          wrong = wrong + 1;
        end
        // The cell is a SINGLE: the next cell draws its own code (the blank 0x0020),
        // never the slot's right 16 bytes (maketext.c:292-294 leaves kanji2nd clear).
        if (obs_b !== 8'h00) begin
          $display("FAIL: ver0.78 code 0x4109 raster %0d: cell1=%02x, the half-width cell must not consume its neighbour",
                   s, obs_b);
          wrong = wrong + 1;
        end
      end
      // The same claim with a right half that is NOT empty, so a wrong pair-consuming
      // fix cannot pass: tagged glyph, left rows all 0xF0, right rows all 0xFF.
      g = 256'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF_F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0;
      load_jis_glyph(8'h29, 8'h22, g);
      fill_jis_plane(8'h29, 8'h22, 8'h20, 8'h00);   // even cells code 0x2209
      spin_one_frame;
      for (s = 0; s < 16; s = s + 1) begin
        sample_pair(s[3:0], obs_a, obs_b);
        if (obs_a !== 8'hF0) begin
          $display("FAIL: ver0.78 code 0x2209 raster %0d: cell0=%02x, the slot's left half is 0xF0",
                   s, obs_a);
          wrong = wrong + 1;
        end
        if (obs_b !== 8'h00) begin
          $display("FAIL: ver0.78 code 0x2209 raster %0d: cell1=%02x, the neighbour draws its own blank space, not the slot's right half 0xFF",
                   s, obs_b);
          wrong = wrong + 1;
        end
      end
      errors = errors + wrong;
      if (wrong == 0)
        $display("  ver0.78 half-width rows: 2 glyphs x 16 rasters matched NP2kai's single-cell draw");
    end

    // ---- the 0xA9 read answers the CURRENT code ----
    // A driver's glyph loop writes the code (0xA1 then 0xA3) and reads 0xA9 right after, one
    // row per read. The guest's read has ONE device wait state (pc9821_iobus S_DEVWAIT) - a
    // registered block-RAM read - while the glyph's SDRAM block is still in flight, so the
    // byte must come from the FONT store. Serving it from the block returned the PREVIOUS
    // code's glyph, i.e. the same glyph repeating over the whole loop (Rusty's menu). The
    // font beats are deliberately NOT delivered here: the store alone must answer.
    begin : check_stale_block
      reg [255:0] g;
      reg [7:0] v;
      integer r, wrong;
      g = sp_glyph[3];                          // ku 0x30 / ten 0x21, FONT.ROM[0xCC20..]
      load_jis_glyph(8'h30, 8'h21, g);          // the store the read must answer from
      write_io(8'hA1, 8'h21);                   // code = {cell, row-0x20} = 0x2110
      write_io(8'hA3, 8'h10);
      wrong = 0;
      for (r = 0; r < 16; r = r + 1) begin
        write_io(8'hA5, 8'h20 | r[7:0]);        // bit 5 set: the left half
        read_io(8'hA9, v);
        if (v !== g[r*8 +: 8]) begin
          $display("FAIL: 0xA9 after a code change read %02x, the store holds %02x (row %0d): the stale block answered",
                   v, g[r*8 +: 8], r);
          wrong = wrong + 1;
        end
      end
      errors = errors + wrong;
      if (wrong == 0)
        $display("  port 0xA9: the changed code's own glyph answered all 16 rows");
    end

    // ---- the CODE fetch's word index is 12 bits, like the attribute's ----
    // The code plane is the TRAM's low 8 KiB (4096 words, bytes 2w and 2w+1) and the attribute
    // plane is 0x2000 + 2w, so the CODE arm's word index must be masked to 12 bits exactly as the
    // attribute arm's is. With 13 bits kept, a word w >= 0x1000 reads its code bytes at 2w, i.e.
    // INSIDE the attribute plane, and the cell's code becomes the attribute byte of word
    // w - 0x1000. `f_wordidx = sad + row*pitch + cell` reaches 0x1000 with a display start (PRAM
    // screen 0) of 0x1000 words - above every word a boot-time 80x25 screen uses (max 1999),
    // which is why no bench or game had seen it. The plane below holds one 2-byte JIS code in
    // every word and 0xE1 in every attribute byte of both parities (the odd byte is the buggy
    // arm's high byte, so it must be defined and not left x), so the whole screen is the
    // assertion: masked, every cell draws the glyph the code names; unmasked, every cell's code
    // is 0xE1E1, whose row 0x81 is outside the stored grid and draws nothing.
    begin : check_code_index12
      reg [7:0] obs_a, obs_b;
      reg [255:0] g;
      integer k, wrong;
      g = sp_glyph[3];                              // ku 0x30 / ten 0x21
      for (k = 0; k < 16'h1000; k = k + 1) begin
        write_tram(k[13:0] * 14'd2,          8'h10);   // code low byte  = ku - 0x20
        write_tram(k[13:0] * 14'd2 + 14'd1,  8'h21);   // code high byte = ten
        write_tram(14'h2000 + k[13:0] * 14'd2,         8'hE1);
        write_tram(14'h2000 + k[13:0] * 14'd2 + 14'd1, 8'hE1);
      end
      load_jis_glyph(8'h30, 8'h21, g);
      // PRAM screen 0 = {sad_lo, sad_hi, len_lo, len_hi} through command 0x70.
      write_io(8'h62, 8'h70);
      write_io(8'h60, 8'h00);
      write_io(8'h60, 8'h10);
      write_io(8'h60, 8'h00);
      write_io(8'h60, 8'h00);
      spin_one_frame;
      spin_one_frame;
      if ({dut.u_crtc.v_sad_hi, dut.u_crtc.v_sad_lo} !== 16'h1000)
        fail("the 0x1000-word display start did not latch");

      wait (frame_ends >= 4);
      while (dut.u_crtc.vline != 9'd15) @(negedge clk_sys);
      lit_l = 0;
      lit_r = 0;
      wrong = 0;
      for (i = 0; i < 16; i = i + 1) begin
        while (dut.u_crtc.hdot != i[9:0]) @(negedge clk_sys);
        if (i == 0 || i == 8) begin
          // The case is only decisive past the 12-bit boundary: assert it is there.
          if (!dut.u_crtc.r_wordidx[12]) begin
            $display("FAIL: the 0x1000-word display start did not reach f_wordidx (r_wordidx=%04x)",
                     dut.u_crtc.r_wordidx);
            wrong = wrong + 1;
          end
          if (dut.u_crtc.r_code_lo !== 8'h10 || dut.u_crtc.r_code_hi !== 8'h21) begin
            $display("FAIL: code fetch over the 12-bit boundary: cell %0d read code %02x%02x, want 1021 (the attribute plane was read as the code plane)",
                     i / 8, dut.u_crtc.r_code_hi, dut.u_crtc.r_code_lo);
            wrong = wrong + 1;
          end
        end
        if (r_out != 0 || g_out != 0 || b_out != 0) begin
          if (i < 8) lit_l = lit_l + 1;
          else       lit_r = lit_r + 1;
        end
      end
      if (!((lit_l == 7 && lit_r == 8) || (lit_l == 8 && lit_r == 7))) begin
        $display("FAIL: code fetch over the 12-bit boundary: scan cells %0d/%0d, want the glyph's 7 and 8 dots",
                 lit_l, lit_r);
        wrong = wrong + 1;
      end
      errors = errors + wrong;
      if (wrong == 0)
        $display("  display start 0x1000 words: code bytes read from the code plane (%02x%02x), 7/8 dots",
                 dut.u_crtc.r_code_hi, dut.u_crtc.r_code_lo);
    end

    // ---- the row cache's bank at the 24 -> 0 WRAP ----
    // The walker banks the cache on the text-row PARITY (it writes wk_row[0], the scanout
    // reads f_row[0]) and fills the NEXT row during the current one. The screen is 25 rows
    // (VACTIVE 400 / 16) and 25 is ODD, so the pair row 24 -> row 0 has the SAME parity:
    // during row 24 the walker fills bank 0 for row 0 while the scanout reads bank 0 for row
    // 24 itself, at the same {bank, cell, word} address. Both operands of that address are
    // the row's own cell, so the write lands on the entry being displayed.
    // Every other JIS check in this bench fills the WHOLE plane with ONE code, so row 0 and
    // row 24 hold the same glyph and none of them can see this. This case gives row 24 its
    // own glyph: if the wrap shares a bank, row 24 draws row 0's glyph instead.
    begin : check_wrap_bank
      reg [7:0] obs_a, obs_b;
      reg [255:0] glyph_a, glyph_b;
      integer r, wrong;
      wrong = 0;
      glyph_a = {32{8'hF0}};   // row 0's glyph: high nibble of every raster byte
      glyph_b = {32{8'h0F}};   // row 24's glyph: the low nibble, so the two cannot be confused
      fill_jis_plane(8'h30, 8'h21, 8'h20, 8'h00);
      load_jis_glyph(8'h30, 8'h21, glyph_a);
      load_jis_glyph(8'h30, 8'h22, glyph_b);
      // Row 24's cell 0 is word 24*80 + 0 = 1920, so its code bytes are TRAM 3840/3841.
      write_tram(14'd3840, 8'h10);   // ku - 0x20
      write_tram(14'd3841, 8'h22);   // ten
      repeat (3) spin_one_frame;
      for (r = 0; r < 16; r = r + 1) begin
        sample_pair_row(5'd24, r[3:0], obs_a, obs_b);
        if (obs_a !== glyph_b[r*8 +: 8]) begin
          $display("MISMATCH wrap: row 24 raster %0d cell0=%02x, row 24's own glyph=%02x, row 0's glyph=%02x (the walker's wrap fill overwrote the row being displayed)",
                   r, obs_a, glyph_b[r*8 +: 8], glyph_a[r*8 +: 8]);
          wrong = wrong + 1;
        end
      end
      errors = errors + wrong;
      if (wrong == 0)
        $display("  wrap: row 24 kept its own glyph across all 16 rasters");
    end

    // ---- the row cache maps DIFFERENT rows to DIFFERENT entries, in general ----
    // check_wrap_bank above samples the 24 -> 0 wrap alone. The bank assignment must hold for
    // every row, and that needs its own case:
    // every other JIS check fills the WHOLE plane with ONE code, so two rows sharing an entry
    // still read the right glyph and hide a mapping error. Here two ADJACENT rows (6 and 7)
    // carry two different glyphs, so the walker's row-7 fill must land in the bank the row-6
    // scanout is NOT reading; each row must then draw its own glyph on all 16 rasters.
    begin : check_row_banks
      reg [7:0] obs_a, obs_b;
      reg [255:0] glyph_p, glyph_q;
      integer r, wrong;
      wrong = 0;
      glyph_p = {32{8'hC3}};   // row 6's own glyph
      glyph_q = {32{8'h3C}};   // row 7's own glyph, unreachable from row 6's code
      fill_jis_plane(8'h30, 8'h21, 8'h20, 8'h00);
      load_jis_glyph(8'h30, 8'h23, glyph_p);
      load_jis_glyph(8'h30, 8'h24, glyph_q);
      // Row R cell 0 is word R*80, so its code bytes are TRAM R*160 for ku and R*160+1 for ten.
      write_tram(14'd960,  8'h10);   // row 6: ku - 0x20
      write_tram(14'd961,  8'h23);   // row 6: ten
      write_tram(14'd1120, 8'h10);   // row 7: ku - 0x20
      write_tram(14'd1121, 8'h24);   // row 7: ten
      repeat (3) spin_one_frame;
      for (r = 0; r < 16; r = r + 1) begin
        sample_pair_row(5'd6, r[3:0], obs_a, obs_b);
        if (obs_a !== glyph_p[r*8 +: 8]) begin
          $display("MISMATCH row 6: raster %0d cell0=%02x, row 6's own glyph=%02x (row 6 shared a bank with another row)",
                   r, obs_a, glyph_p[r*8 +: 8]);
          wrong = wrong + 1;
        end
      end
      // Rows 6 and 7 are consecutive, so this is the SAME frame: the second loop continues from
      // vline 111 to 112 rather than waiting for the next frame.
      for (r = 0; r < 16; r = r + 1) begin
        sample_pair_row(5'd7, r[3:0], obs_a, obs_b);
        if (obs_a !== glyph_q[r*8 +: 8]) begin
          $display("MISMATCH row 7: raster %0d cell0=%02x, row 7's own glyph=%02x (row 7 shared a bank with another row)",
                   r, obs_a, glyph_q[r*8 +: 8]);
          wrong = wrong + 1;
        end
      end
      errors = errors + wrong;
      if (wrong == 0)
        $display("  row banks: rows 6 and 7 each kept their own glyph across all 16 rasters");
    end

    // ---- row 0 tracks the frame that DRAWS it, not the one that filled it ----
    // Row 0's cache is filled a whole frame early (during row 24), so a display-start change that
    // commits at the frame boundary used to leave row 0 drawing the previous frame's mapping. The
    // fix commits at vline 431 and re-walks row 0 in the vline-432 slot, so the FIRST frame after
    // the change draws the new mapping (issue I2). Without the re-walk this case's
    // rasters 1-15 all show the previous mapping's glyph.
    // Raster 0 is excluded on purpose: the scanout's cross-frame prefetch reads row 0 cell 0 during
    // vline 399, before the snapshot, so that one cell/one raster is inherently one frame behind - no
    // commit point after vline 399 can reach it. That is a 1-cell, 1-raster artifact, not the
    // row-0-wide staleness this case distinguishes.
    begin : check_row0_scroll
      reg [7:0] obs_a, obs_b;
      reg [255:0] glyph_a, glyph_b;
      integer r, wrong;
      reg [5:0] f0;
      wrong = 0;
      glyph_a = {32{8'hF0}};   // row 0 cell 0 with display start word 0
      glyph_b = {32{8'h0F}};   // row 0 cell 0 with display start word 1
      // sad = 0: row 0 cell 0 is TRAM word 0. sad = 1: it is word 1.
      write_tram(14'd0, 8'h10);   // word 0: ku - 0x20
      write_tram(14'd1, 8'h21);   // word 0: ten
      write_tram(14'd2, 8'h10);   // word 1: ku - 0x20
      write_tram(14'd3, 8'h22);   // word 1: ten
      write_tram(14'h2000, 8'hE1);
      write_tram(14'h2002, 8'hE1);
      load_jis_glyph(8'h30, 8'h21, glyph_a);
      load_jis_glyph(8'h30, 8'h22, glyph_b);
      repeat (2) spin_one_frame;
      // Before the change, with display start 0, row 0 cell 0 draws the old mapping's glyph.
      sample_pair_row(5'd0, 4'd8, obs_a, obs_b);
      if (obs_a !== glyph_a[8*8 +: 8]) begin
        $display("FAIL row0-scroll: with display start 0, row 0 raster 8 cell0=%02x, want %02x",
                 obs_a, glyph_a[8*8 +: 8]);
        wrong = wrong + 1;
      end
      // Move the display start to word 1 early in a frame that the sample below does not read.
      while (dut.u_crtc.vline != 9'd5) @(negedge clk_sys);
      write_io(8'h62, 8'h70);
      write_io(8'h60, 8'h01);
      write_io(8'h60, 8'h00);
      write_io(8'h60, 8'h00);
      write_io(8'h60, 8'h00);
      // Its commit lands at this frame's vline 431; the NEXT frame draws row 0 with it.
      next_frame();
      for (r = 1; r < 16; r = r + 1) begin
        sample_pair_row(5'd0, r[3:0], obs_a, obs_b);
        if (obs_a !== glyph_b[r*8 +: 8]) begin
          $display("MISMATCH row0-scroll: raster %0d cell0=%02x, the frame's own glyph=%02x, the previous frame's=%02x",
                   r, obs_a, glyph_b[r*8 +: 8], glyph_a[r*8 +: 8]);
          wrong = wrong + 1;
        end
      end
      errors = errors + wrong;
      if (wrong == 0)
        $display("  row0 scroll: row 0 drew the frame's own display start on rasters 1-15");
      // Restore display start 0 for the case below.
      write_io(8'h62, 8'h70);
      write_io(8'h60, 8'h00);
      write_io(8'h60, 8'h00);
      write_io(8'h60, 8'h00);
      write_io(8'h60, 8'h00);
      repeat (2) spin_one_frame;
    end

    // ---- the row cache's bank at the wrap, in 40-COLUMN mode ----
    // The row cache, the bank expression and the walker are shared with 80-column mode, but only
    // 80 columns was covered above and the walker's cell stride changes with v_col40 (two words
    // per cell). If the bank mapping were 80-column-only, or the walker's stride were not keyed on
    // v_col40, the wrap alias would come back here and nowhere else (issue I33). The
    // scenario is check_wrap_bank's: row 0 and row 24 cell 0 both JIS, row 24's cell 0 given its
    // own glyph, and row 24 must keep it. Cell 0 is TRAM word row*80 in BOTH modes (the 40-column
    // stride doubles only from cell 1), so the same code bytes carry it.
    begin : check_wrap_col40
      reg [7:0] obs_a;
      reg [255:0] glyph_a, glyph_b;
      integer r, wrong;
      wrong = 0;
      glyph_a = {32{8'hF0}};   // row 0's glyph
      glyph_b = {32{8'h0F}};   // row 24's own glyph, unreachable from row 0's code
      // mode1[2] = 40 columns: port 0x68, bit = (dat>>1)&7, on = dat&1.
      write_io(8'h68, 8'h05);
      fill_jis_plane(8'h30, 8'h21, 8'h20, 8'h00);
      load_jis_glyph(8'h30, 8'h21, glyph_a);
      load_jis_glyph(8'h30, 8'h22, glyph_b);
      write_tram(14'd3840, 8'h10);   // row 24 cell 0: ku - 0x20
      write_tram(14'd3841, 8'h22);   // row 24 cell 0: ten
      repeat (3) spin_one_frame;
      if (!dut.u_crtc.v_col40) fail("the 40-column bit did not reach the scanout snapshot");
      for (r = 0; r < 16; r = r + 1) begin
        sample_col40_row(5'd24, r[3:0], obs_a);
        if (obs_a !== glyph_b[r*8 +: 8]) begin
          $display("MISMATCH wrap 40-col: row 24 raster %0d cell0=%02x, row 24's own glyph=%02x, row 0's glyph=%02x",
                   r, obs_a, glyph_b[r*8 +: 8], glyph_a[r*8 +: 8]);
          wrong = wrong + 1;
        end
      end
      errors = errors + wrong;
      if (wrong == 0)
        $display("  wrap 40-col: row 24 kept its own glyph across all 16 rasters");
      write_io(8'h68, 8'h04);   // back to 80 columns
      repeat (2) spin_one_frame;
    end

    // ---- the 0xA4 display-page flip applies IMMEDIATELY at the write ----
    // ReC98's page_show(0xA4) selects the page the scanout reads (page.hpp). That bit is a
    // page-SELECT mux outside the GDC - it chooses which 32 KiB plane the chip's LOW15 address
    // counter reads - so it applies at the write, not at a display-scan load. MAME
    // (pc9801_v.cpp:441 `m_vram_disp`, used live at :64-68), NP2kai (io/gdc.c:733 `gdcs.disp`) and
    // qemu-pc98 (pc98-vga.c:3424 `vram16_disp_*`) all apply it combinationally, and the real
    // 33 MHz Xe capture (docs/probes/FLIP.TXT) shows the SPLIT that only apply-at-the-write can produce.
    // An earlier `if (frame_end) v_page <= display_page` was therefore wrong: it delayed the
    // guest's flip by up to a frame, so the game drew into the page the scanout still showed - the
    // erased sprite band that is the blackout. This case is FAIL-FIRST against that latch: each
    // arm writes at a point where a frame-end latch could not have applied it by the sample, so
    // every arm fails on the frame-end-latch tree and passes here.
    begin : check_display_flip
      integer arm, hd;
      reg [8:0] vl;
      reg [8*90-1:0] msg;
      for (arm = 0; arm < 3; arm = arm + 1) begin
        // (vline, hdot):
        //   arm 0  vline 439 hdot 0   - early on the last line, a control
        //   arm 1  vline 439 hdot 844 - the frame-end latch's drop window, the last dots before frame_end
        //   arm 2  vline 200 hdot 400 - mid active region: the tear the probe records
        vl = (arm == 2) ? 9'd200 : 9'd439;
        hd = (arm == 0) ? 0 : ((arm == 1) ? 844 : 400);
        // Park on page 0 first - an immediate clear - and verify it, so a stale page cannot pass.
        write_io(8'hA4, 8'h00);
        if (gfx_line_addr[15] !== 1'b0) fail("the 0xA4 clear did not reach the scanout page");
        while (dut.u_crtc.vline != vl || dut.u_crtc.hdot != hd[9:0]) @(negedge clk_sys);
        write_io(8'hA4, 8'h01);
        #1;   // the write's own clk_sys edge already applied it; no frame boundary in between
        msg = (arm == 2)
            ? "a 0xA4 write in the active region was not applied immediately"
            : "a 0xA4 write near vline 439 was not applied immediately";
        if (gfx_line_addr[15] !== 1'b1) fail(msg);
        else $display("  display flip: 0xA4 write at vline %0d hdot %0d reached the scan page the next cycle", vl, hd);      end
    end

    // ---- the walker never skipped a walk slot in this run (issue I4) ----
    // A skipped walk is a contention timing failure with no other detector. The counter is
    // saturating and sticky, so on a bench whose walker has a whole row of slack it must be 0. It
    // is also the field pc9821_gfx_msg's record carries to the card. TAKEN HERE, before the
    // machine-reset block below: that block asserts rst_n_sys, which clears this sticky counter,
    // so the evidence has to be read first or the check would pass vacuously over the whole run.
    if (dbg_wk_skips !== 16'h0000) begin
      $display("FAIL: the walker skipped %0d walk slot(s)", dbg_wk_skips);
      errors = errors + 1;
    end else
      $display("  walk skips: 0 (the walker never overran its row)");

    // ---- the MACHINE-RESET seed reaches the CG record too ----
    // The record, the DIP port mirror and the software-DIP bank are re-seeded by ONE event:
    // pc9821_system ORs the iobus's reset-seed one-shot into `cg_record_restore`, the same line
    // the two OSD actions use. pc9821_cg's own reset (`rst_n_sys`) is clamped for the WHOLE
    // machine-reset window, so the property to pin is that the walk is NOT reset-held: it runs
    // DURING that window (all three port-sharing gates - cg_we, cg_rd_win, io_rd - are idle
    // there), which is what lets the 38 bytes be back before the CPU can leave its own reset and
    // read the marker at 0xFC681. FAIL-FIRST: with the walk under `!rst_n_sys` the strobe is
    // swallowed and the corrupt record survives the reset.
    begin
      integer r, wrong;
      // (1) Corrupt the record through the guest's own 0xA9 path (row 8 = store 0x818) and the
      // mirror the same way (code 0x0156 row 1 = store 0x51).
      write_io(8'hA1, 8'h20);
      write_io(8'hA3, 8'h56);
      write_io(8'hA5, 8'h08);
      write_io(8'hA9, 8'h3C);
      if (dut.u_cg.u_cg_ram.ram[13'h818] !== 8'h3C)
        fail("the machine-reset record check is vacuous: the guest write never moved the record");
      write_io(8'hA1, 8'h01);
      write_io(8'hA3, 8'h56);
      write_io(8'hA5, 8'h01);
      write_io(8'hA9, 8'h3C);
      if (dut.u_cg.u_cg_ram.ram[13'h051] !== 8'h3C)
        fail("the machine-reset mirror check is vacuous: the write did not move the mirror");
      // (2) The machine reset, with the restoring strobe inside it - exactly what pc9821_system's
      // OR of the reset seed produces. The walk is one byte per clk_sys here: 14 record bytes
      // first, then the mirror's 24, and all 38 must fit before the release the CPU side waits
      // for (the iobus's 24-step walk plus the reset gate's 15-cycle hold buy 39).
      rst_n_sys = 1'b0;
      repeat (2) @(posedge clk_sys);
      cg_record_restore = 1'b1;
      repeat (2) @(posedge clk_sys);
      cg_record_restore = 1'b0;
      repeat (38) @(posedge clk_sys);
      if (dut.u_cg.cg_rec_busy)
        fail("the CG restore walk was still running 40 clk_sys after the reset-window strobe");
      wrong = 0;
      for (r = 0; r < 14; r = r + 1)
        if (dut.u_cg.u_cg_ram.ram[13'h810 + r] !== cg_rec_powerup[r]) wrong = wrong + 1;
      if (wrong != 0) begin
        $display("FAIL the machine-reset seed did not restore the CG record inside the reset window (%0d of 14 bytes differ)", wrong);
        errors = errors + 1;
      end
      // The firmware-visible half: the marker pair the ITF's 0xFC681 check compares.
      if (dut.u_cg.u_cg_ram.ram[13'h818] !== 8'hAA || dut.u_cg.u_cg_ram.ram[13'h819] !== 8'h55)
        fail("the restored CG record lost the ITF's AA55 marker");
      // And the mirror the FC42D copy would deliver from: bank A row 1 (0x51) is the
      // measured machine byte again, not the corrupting write.
      if (dut.u_cg.u_cg_ram.ram[13'h051] !== 8'h02)
        fail("the machine-reset seed did not restore the DIP mirror inside the reset window");
      rst_n_sys = 1'b1;
      repeat (4) @(posedge clk_sys);
    end

    // ---- SIMPLE GRAPHICS (MODE FF1 bit 0, attribute bit 4) ----
    // NP2kai maketext.c: an ANK cell whose attribute has TXTATR_BG (0x10) while gdc.mode1 & 1
    // reads its glyph from the character-graph bank (`bitmap[x] += 0x1000`, i.e. fontrom
    // 0x81000 + code * 16 in the 8x16 font) instead of the ANK glyph, and font.c:39
    // font_setchargraph builds that bank: glyph row r of code c is 0xF0 if c bit (r >> 2) is set,
    // OR 0x0F if c bit 4 + (r >> 2) is set, with code 0xF2's first two rows cleared (the NEC
    // patch, `!epson`). sg_ref below is that loop, transcribed. Cell 0 = 0x5A, cell 1 = 0xF2,
    // both attribute 0xF1 (white, visible, bit 4). FAIL-FIRST: the pre-change core drew the ANK
    // glyph (blank here) and used mode1 bit 0 only to suppress the vertical line.
    begin : sg_check
      integer r, bad;
      reg [7:0] oa, ob, ea, eb;
      bad = 0;
      write_io(8'h62, 8'h0D);              // BCTRL on again: the record section above reset the core
      write_tram(14'h0000, 8'h5A); write_tram(14'h0001, 8'h00); write_tram(14'h2000, 8'hF1);
      write_tram(14'h0002, 8'hF2); write_tram(14'h0003, 8'h00); write_tram(14'h2002, 8'hF1);
      write_io(8'h68, 8'h01);              // MODE FF1 bit 0: simple graphics
      next_frame(); next_frame();
      for (r = 0; r < 16; r = r + 1) begin
        ea = sg_ref(8'h5A, r[3:0]); eb = sg_ref(8'hF2, r[3:0]);
        sample_pair(r[3:0], oa, ob);
        if (oa !== ea || ob !== eb) begin
          $display("FAIL simple graphics row %0d: cells %02x %02x, NP2kai %02x %02x", r, oa, ob, ea, eb);
          bad = bad + 1;
        end
      end
      // and with mode1 bit 0 clear the same cells are ANK glyphs again (blank here) - the
      // attribute bit is the vertical line then
      write_io(8'h68, 8'h00);
      next_frame(); next_frame();
      sample_pair(4'd5, oa, ob);
      if (oa !== 8'h08 || ob !== 8'h08) begin
        $display("FAIL simple graphics off: row 5 cells %02x %02x, expected the vertical line only (08 08)", oa, ob);
        bad = bad + 1;
      end
      errors = errors + bad;
      write_tram(14'h2000, 8'h00); write_tram(14'h2002, 8'h00);
    end

  // ==== VERDICT ====
    if (errors == 0) begin
        $display("TB_PC9821_GDC_TEXT: PASS");
        $finish;
    end
    else $fatal(1, "TB_PC9821_GDC_TEXT: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog. Measured: 2 M cycles is NOT enough for this bench (it timed out at
  // 20 ms), and the two row-cache cases (check_wrap_bank and check_row_banks) each cost a few
  // frames of settling, so with them the bench finishes at ~106 ms. 200 ms leaves ~1.9x over
  // that measured run.
  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_GDC_TEXT: TIMEOUT");
  end

endmodule
