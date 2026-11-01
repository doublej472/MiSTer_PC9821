`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_CG_GAIJI_RECORD:
// A user-defined character the guest writes into the CG store cells that also hold the configuration image (code 0x2056 - store 0x810..0x81D, the software-DIP record - and code 0x1256 row 7, store 0x0497) is what the text plane DRAWS for a cell carrying that code: with the configuration view ENABLED (cfg_seed_en = 1, as pc9821_system ties it), the machine's own INT 18h AH=1Ah sequence (A3=0x56, A1=DL, A5=0x00 then 0x20, 32 bytes through the 0xA4000 window - F000:EBD7 in the Xe10 BIOS) loading Flame Zapper Kotsujin's glyph 0 (CO2JIN.FNT, all zero - the game's SPACE, code 0x7620) must render a blank 16x16 pair, and a patterned glyph loaded at 0x7612 must render exactly the bytes written, row for row, in both halves. The CPU-side configuration view is unchanged: after the ITF's re-POST (cfg_seed_reload) the record still reads its static image through port 0xA9 (row 5 = 0xFF, row 8 = 0xAA). FAIL-FIRST: with the write gate suppressing guest stores to those twenty cells, the scanout drew the record bytes (04 C1 8C 81 CD FF 00 00 AA 55 67 86 8A FF) as the right half of every Kotsujin space - the red/yellow/white/pink garbage glyphs a GAME OVER screenshot showed.
//
// Expected values are the GUEST's bytes (the game's font file and a written pattern), not
// this RTL's: the machine's CG store is guest-writable at these cells - the ITF's own
// stage-1A KANJI CG-RAM test writes 0FFh/00h over the whole store and verifies it on the
// machine (BANK4@0xF8061-0xF80F4), and the BIOS's AH=1Ah handler writes the window with no
// code-range check.

module tb_pc9821_cg_gaiji_record;
  reg clk_sys = 0;
  always #5 clk_sys = ~clk_sys;
  reg pixel_ce = 1;
  reg rst_n_sys = 0;
  reg io_wr = 0;
  reg io_rd = 0;
  reg [7:0] io_addr = 0, io_din = 0;
  wire gfx_access_page;
  wire [15:0] gfx_line_addr;
  wire gfx_walk_page;
  wire [7:0] io_dout;
  reg [13:0] tram_cpu_addr = 0;
  reg [7:0] tram_cpu_din = 0;
  reg tram_cpu_we = 0;
  wire [7:0] tram_cpu_dout;
  reg  [4:0] cg_win_byte_sel = 0;
  reg  cg_win_rd = 0;
  wire [7:0] cg_win_dout;
  reg  [7:0] cg_win_din = 0;
  reg  cg_win_we = 0;
  wire [18:0] font_req_addr;
  wire font_req;
  reg  font_word_valid = 0;
  reg  [31:0] font_word_data = 0;
  reg [17:0] font_ld_addr = 0;
  reg [15:0] font_ld_data = 0;
  reg font_ld_we = 0;
  wire vsync_active, disp_on;
  wire [6:0] cfg_ram_mib = 7'd16;
  wire       cfg_seed_en = 1'b1;        // the configuration view ON, as pc9821_system ties it
  reg        cfg_seed_reload = 1'b0;
  wire gfx_disp;
  wire vsync_irq_arm = 1'b0;
  wire vsync_irq;
  wire vsync_edge;
  wire        text_opaque, text_cell;
  wire [11:0] text_colour;
  wire [9:0]  pix_dot;
  wire        pix_h_active, pix_v_active;
  wire        gfx_mode16;
  wire [31:0] gfx_dig;
  wire        pal_wr_en;
  wire [3:0]  pal_wr_idx;
  wire [1:0]  pal_wr_chan;
  wire [3:0]  pal_wr_data;
  wire        pal_commit;
  wire hs_out, vs_out, de_out;
  reg cg_record_restore = 0;
  reg [3:0] bios_set = 4'd0;
  wire gfx_egc_gate;
  wire [15:0] dbg_sad;
  wire  [7:0] dbg_pitch;
  wire        dbg_col40, dbg_disp;
  wire [15:0] dbg_wk_skips;
  wire cg_rd_hold, cg_win_byte_hold;
  wire gfx_odd_line;
  reg [2:0] cfg_fdd_mode = 3'd0;

  // ==== DUT ====
  pc9821_gdc_text_dut dut (.*);

  integer i, r, errors = 0;
  reg [7:0] value, obs_l, obs_r;

  // A lit dot is any non-black pixel: attribute 0xE1 is white, visible.
  wire lit = text_opaque && (text_colour != 12'h000);

  // ==== STIMULUS ====
  task automatic fail(input [8*96-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task automatic write_io(input [7:0] portnum, input [7:0] data);
    begin
      @(negedge clk_sys);
      io_addr = portnum; io_din = data; io_wr = 1;
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
      tram_cpu_addr = addr; tram_cpu_din = data; tram_cpu_we = 1;
      @(negedge clk_sys);
      tram_cpu_we = 0;
    end
  endtask

  // One byte through the 0xA4000 window: window offset `ofs` is byte_sel {ofs[0], ofs[4:1]}
  // (pc9821_window_responder: `assign byte_sel = {indexed_addr[0], indexed_addr[4:1]}`).
  task automatic win_write(input [4:0] ofs, input [7:0] data);
    begin
      @(negedge clk_sys);
      cg_win_byte_sel = {ofs[0], ofs[4:1]}; cg_win_din = data; cg_win_we = 1;
      @(negedge clk_sys);
      cg_win_we = 0;
    end
  endtask

  // The Xe10 BIOS's INT 18h AH=1Ah body (F000:EBD7..EC11), byte for byte in effect:
  //   out A3,lo ; out A1,hi ; out 68,0Bh ; out A5,00h ; rep movsw 16 words -> A400:0000
  //   out A5,20h ; 16x { lodsw ; mov ah,al ; stosw }        (buffer rewound by 0x20)
  // `left[r]`/`right[r]` are the font file's row bytes (CO2JIN.FNT: 2 bytes per row, left
  // first), so the buffer word r is {right[r], left[r]}.
  reg [7:0] g_left [0:15];
  reg [7:0] g_right[0:15];
  task automatic bios_define_char(input [7:0] code_lo, input [7:0] code_hi);
    integer k;
    begin
      write_io(8'hA3, code_lo);
      write_io(8'hA1, code_hi);
      write_io(8'hA5, 8'h00);
      for (k = 0; k < 16; k = k + 1) begin
        win_write(5'(2*k),     g_left[k]);
        win_write(5'(2*k + 1), g_right[k]);
      end
      write_io(8'hA5, 8'h20);
      for (k = 0; k < 16; k = k + 1) begin
        win_write(5'(2*k),     g_left[k]);
        win_write(5'(2*k + 1), g_left[k]);
      end
    end
  endtask

  // Sample the 16 dots of cells {2*pair, 2*pair+1} on text row 0, raster `raster`.
  task automatic sample_pair(input integer pair, input [3:0] raster,
                             output [7:0] o_l, output [7:0] o_r);
    integer k;
    begin
      while (dut.u_crtc.vline != {6'd0, raster}) @(negedge clk_sys);
      o_l = 8'h00; o_r = 8'h00;
      for (k = 0; k < 16; k = k + 1) begin
        while ({22'd0, dut.u_crtc.hdot} != (16*pair + k)) @(negedge clk_sys);
        if (k < 8) o_l[7-k] = lit; else o_r[7-(k-8)] = lit;
      end
    end
  endtask

  integer frame_ends = 0;
  always @(posedge clk_sys) if (rst_n_sys && dut.u_crtc.frame_end) frame_ends <= frame_ends + 1;

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk_sys);
    @(negedge clk_sys);
    rst_n_sys = 1;
    // The machine-reset seed: the record and the DIP mirror are in the store, as at boot.
    cg_record_restore = 1'b1;
    repeat (2) @(posedge clk_sys);
    cg_record_restore = 1'b0;
    repeat (60) @(posedge clk_sys);
    if (dut.u_cg.u_cg_ram.ram[13'h818] !== 8'hAA || dut.u_cg.u_cg_ram.ram[13'h819] !== 8'h55)
      fail("precondition: the record is not in the store at code 0x2056 (rows 8/9 != AA55)");

    // The text plane: ANK spaces everywhere, then two gaiji pairs exactly as Kotsujin's
    // put-char (COTSUJIN.COM 0xBFBF) writes them - [0x56,c] then [0xD6,c], attribute 0xE1.
    for (i = 0; i < 2000; i = i + 1) begin
      write_tram(i[13:0]*14'd2, 8'h20);
      write_tram(i[13:0]*14'd2 + 14'd1, 8'h00);
      write_tram(14'h2000 + i[13:0]*14'd2, 8'h00);
    end
    write_tram(14'h0000, 8'h56); write_tram(14'h0001, 8'h20); write_tram(14'h2000, 8'hE1);
    write_tram(14'h0002, 8'hD6); write_tram(14'h0003, 8'h20); write_tram(14'h2002, 8'hE1);
    write_tram(14'h0004, 8'h56); write_tram(14'h0005, 8'h12); write_tram(14'h2004, 8'hE1);
    write_tram(14'h0006, 8'hD6); write_tram(14'h0007, 8'h12); write_tram(14'h2006, 8'hE1);

    // Glyph 0 of CO2JIN.FNT (GJLOAD's DX = 0x7620): 32 zero bytes - the game's SPACE.
    for (r = 0; r < 16; r = r + 1) begin g_left[r] = 8'h00; g_right[r] = 8'h00; end
    bios_define_char(8'h56, 8'h20);
    // A patterned glyph at 0x7612 (store 0x0480..0x049F, which holds the CPU-mode cell
    // 0x0497 = right half row 7): every row distinct in both halves.
    for (r = 0; r < 16; r = r + 1) begin
      g_left[r]  = 8'h11 * r[7:0] ^ 8'h80;
      g_right[r] = 8'h0F ^ (r[7:0] << 4) ^ 8'h01;
    end
    bios_define_char(8'h56, 8'h12);
    write_io(8'h62, 8'h0D);   // BCTRL START

    wait (frame_ends >= 3);
    // Pair 0: Kotsujin's space must be blank in all 16 rows of both halves.
    for (r = 0; r < 16; r = r + 1) begin
      sample_pair(0, r[3:0], obs_l, obs_r);
      if (obs_l !== 8'h00 || obs_r !== 8'h00) begin
        $display("FAIL: code 0x7620 row %0d drew %02x %02x, the guest wrote 00 00", r, obs_l, obs_r);
        errors = errors + 1;
      end
    end
    // Pair 1: the patterned glyph, both halves, row for row.
    for (r = 0; r < 16; r = r + 1) begin
      sample_pair(1, r[3:0], obs_l, obs_r);
      if (obs_l !== (8'h11 * r[7:0] ^ 8'h80) || obs_r !== (8'h0F ^ (r[7:0] << 4) ^ 8'h01)) begin
        $display("FAIL: code 0x7612 row %0d drew %02x %02x, the guest wrote %02x %02x", r,
                 obs_l, obs_r, 8'h11 * r[7:0] ^ 8'h80, 8'h0F ^ (r[7:0] << 4) ^ 8'h01);
        errors = errors + 1;
      end
    end

    // The CPU-side view is untouched: after the re-POST the record reads its static image.
    cfg_seed_reload = 1'b1;
    @(negedge clk_sys);
    cfg_seed_reload = 1'b0;
    @(negedge clk_sys);
    write_io(8'hA1, 8'h20);
    write_io(8'hA3, 8'h56);
    write_io(8'hA5, 8'h05);
    read_io(8'hA9, value);
    if (value !== 8'hFF) fail("after the re-POST record row 5 (0x815) did not read its static 0xFF");
    write_io(8'hA5, 8'h08);
    read_io(8'hA9, value);
    if (value !== 8'hAA) fail("after the re-POST record row 8 (0x818) did not read its static 0xAA");

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_CG_GAIJI_RECORD: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_CG_GAIJI_RECORD: FAIL (%0d errors)", errors);
  end

  initial begin
    #100_000_000;
    $fatal(1, "TB_PC9821_CG_GAIJI_RECORD: TIMEOUT");
  end

endmodule
