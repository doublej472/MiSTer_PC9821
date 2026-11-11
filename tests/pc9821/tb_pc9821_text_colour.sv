`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_TEXT_COLOUR:
// The text plane's colour contract, from the attribute byte to the RGB wires, and the byte the machine's own BIOS reads to choose that colour: every attribute colour index renders through the fixed 8-colour text table (R=idx1, G=idx2, B=idx0) and does NOT change when the graphics palette ports 0xA8/0xAA/0xAC/0xAE are programmed, and the eight text-VRAM memory-switch bytes survive the guest's attribute-plane fill because MODE FF1 bit 6 is their write enable -- which is what keeps the BIOS's console attribute white (0xE1) instead of green (0x81).

// The two things this file exists for, both machine- or firmware-sourced:
//
// 1. Text colour is the attribute, not the palette. Both references give the
//    text plane a fixed 8-entry table built from the three attribute colour
//    bits and use it in the 16-colour, 256-colour and digital paths alike (QEMU
//    pc98-vga.c:4214-4218 builds it with r=i&2, g=i&4, b=i&1 and uses it
//    unconditionally for text pixels; NP2kai vram/palettes.c:99-108 degpal1,
//    installed as the text palette by pal_maketext/pal_maketext256), while
//    0xA8/0xAA/0xAC/0xAE drive the *graphics* palette only. The machine's own
//    text attributes agree with that order: its captured screen holds 0x81 in
//    green cells, 0x21 for blue and 0xE1 for the bulk of the text
//    (probes/R10.TXT, the machine's probe results).
//
// 2. Memory switch 3 (TRAM byte 0xA3FEA) decides white vs green. The main
//    BIOS's console reads it and picks its console attribute from bit 6
//    (BIOS.ROM bank 6: `mov bx,0xEA; call 0x21D1` reads segment 0xA3F0 offset
//    0xEA = 0xA3FEA; then `mov byte [0x43A],0xE1; test al,0x40; mov byte
//    [0x43A],0x81` at 0x226F-0x2287, used as the console attribute through
//    0x524D). The switch bytes are write-protected until MODE FF1 bit 6 is set
//    -- the ITF brackets every switch write with `out 0x68,0x0D`/
//    `out 0x68,0x0C` and tests the cells in between (BANK4.BIN@0x1D1B and the
//    write test at 0x5AFE-0x5B39) -- and the machine's tail proves the protect
//    covers exactly those bytes: the screen attribute fill reaches their
//    neighbours (0xA3FE0/0xA3FE4 read 0xE1) while 0xA3FE2+4i keep the switch
//    record 48 05 0C 00 01 .. 81. Without the protect the guest's own fill
//    (which walks every even address of the 8 KiB attribute plane) overwrites
//    the record with its attribute 0xE1, bit 6 of switch 3 becomes set, and the
//    BIOS draws its whole screen green where the machine draws it white.

`default_nettype none

module tb_pc9821_text_colour;
  reg clk = 0;
  always #5 clk = ~clk;
  reg clk_vid_ce = 1;
  reg reset = 1;
  reg rst_n = 0;

  // ---- the CPU side of text VRAM, through the real byte path ----
  reg [13:0] cpu_addr = 0;
  reg [31:0] cpu_din = 0;
  reg [3:0] cpu_be = 0;
  reg cpu_line_read = 0, cpu_valid = 0, cpu_write = 0;
  wire [31:0] cpu_dout;
  wire [31:0] cpu_line_word;
  wire cpu_ready, cpu_resp_valid, cpu_line_word_valid;
  wire [13:0] tram_addr;
  wire [7:0] tram_din;
  wire tram_we;
  wire [7:0] tram_dout;

  // ---- I/O ports, as pc9821_system drives them ----
  reg io_wr = 0, io_rd = 0;
  reg [7:0] io_addr = 0, io_din = 0;
  wire [7:0] io_dout;

  // ---- the rest of gdc_text's pins, parked except the two video outputs ----
  reg [10:0] font_ld_addr = 0;
  reg [15:0] font_ld_data = 0;
  reg font_ld_we = 0;
  reg [4:0] cg_win_byte_sel = 0;
  reg cg_win_rd = 0;
  wire [7:0] cg_win_dout;
  reg [7:0] cg_win_din = 0;
  reg cg_win_we = 0;
  wire [18:0] font_req_addr;
  wire font_req;
  reg font_word_valid = 0;
  reg [31:0] font_word_data = 0;
  reg cg_record_restore = 0;
  wire vsync_active, vsync_irq, disp_on, gfx_access_page;
  wire vsync_irq_arm;
  // The text plane leaves pc9821_gdc_text as a colour and two opacity flags now
  // ("no text here" is no longer the same three bytes as black).
  // This bench reconstructs what the framework used to see, so its pixel
  // assertions keep exactly the meaning they had.
  wire        text_opaque, text_cell;
  wire [11:0] text_colour;
  wire [7:0]  r_out = text_opaque ? {text_colour[11:8], text_colour[11:8]} : 8'h00;
  wire [7:0]  g_out = text_opaque ? {text_colour[7:4],  text_colour[7:4]}  : 8'h00;
  wire [7:0]  b_out = text_opaque ? {text_colour[3:0],  text_colour[3:0]}  : 8'h00;
  wire hs_out, vs_out, de_out;
  wire [15:0] dbg_sad;
  wire [7:0] dbg_pitch;
  wire dbg_col40, dbg_disp;

  // The merged responder's idle CG byte port (see the DUT below).
  wire [4:0] byte_sel_unused;
  wire       byte_rd_unused;
  wire [7:0] byte_din_unused;
  wire       byte_we_unused;

  // ==== DUT ====
  // The TRAM arm of the one byte-window responder the TRAM bridge and the CG window are
  // now (route_cg = 0); its CG byte port is idle on this route.
  wire       unused_dma_ready, unused_dma_resp;
  wire [7:0] unused_dma_dout;
  pc9821_window_responder u_bridge (
      .clk(clk), .reset(reset), .route_cg(1'b0),
      .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_be(cpu_be),
      .cpu_line_read(cpu_line_read), .cpu_valid(cpu_valid),
      .cpu_write(cpu_write), .cpu_dout(cpu_dout),
      .cpu_line_word(cpu_line_word), .cpu_ready(cpu_ready),
      .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_word_valid(cpu_line_word_valid),
      // The DMA port is idle here: no bus-master byte reaches the text RAM in this bench.
      .dma_route_cg(1'b0), .dma_valid(1'b0), .dma_write(1'b0), .dma_addr(14'd0), .dma_din(8'h00),
      .dma_ready(unused_dma_ready), .dma_resp_valid(unused_dma_resp), .dma_dout(unused_dma_dout),
      .tram_addr(tram_addr), .tram_din(tram_din), .tram_we(tram_we),
      .tram_dout(tram_dout),
      .byte_sel(byte_sel_unused), .byte_rd(byte_rd_unused),
      .byte_dout(8'h00), .byte_hold(1'b0),
      .byte_din(byte_din_unused), .byte_we(byte_we_unused)
  );

  pc9821_gdc_text_dut u_gdc (
      .clk_sys(clk), .rst_n_sys(rst_n),
      .cfg_fdd_mode(3'd0),   // entry 0: the measured boot/FDD nibble
      .pixel_ce(clk_vid_ce),
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din),
      .io_dout(io_dout),
      .tram_cpu_addr(tram_addr), .tram_cpu_din(tram_din),
      .tram_cpu_we(tram_we), .tram_cpu_dout(tram_dout),
      .font_ld_addr(font_ld_addr), .font_ld_data(font_ld_data),
      .font_ld_we(font_ld_we),
      .cg_win_byte_sel(cg_win_byte_sel), .cg_win_rd(cg_win_rd),
      .cg_win_dout(cg_win_dout), .cg_win_din(cg_win_din), .cg_win_we(cg_win_we),
      .font_req_addr(font_req_addr), .font_req(font_req),
      .font_word_valid(font_word_valid), .font_word_data(font_word_data),
      .cg_record_restore(cg_record_restore),
      .cfg_seed_reload(1'b0),
      .vsync_active(vsync_active), .vsync_irq_arm(vsync_irq_arm),
      .vsync_irq(vsync_irq), .disp_on(disp_on),
      .gfx_access_page(gfx_access_page),
      .dbg_sad(dbg_sad), .dbg_pitch(dbg_pitch),
      .dbg_col40(dbg_col40), .dbg_disp(dbg_disp),
      .text_opaque(text_opaque), .text_cell(text_cell),
      .text_colour(text_colour),
      .hs_out(hs_out), .vs_out(vs_out), .de_out(de_out)
  );

  assign vsync_irq_arm = 1'b0;

  integer errors = 0;
  integer i, k, pass;
  reg [7:0] value;
  reg [7:0] sr, sg, sb;
  reg [23:0] rgb, want;

  // ==== STIMULUS ====

  task automatic fail(input [8*96-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task automatic write_io(input [7:0] portnum, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = portnum;
      io_din = data;
      io_wr = 1;
      @(negedge clk);
      io_wr = 0;
    end
  endtask

  task automatic write_font(input [10:0] addr, input [15:0] data);
    begin
      @(negedge clk);
      font_ld_addr = addr;
      font_ld_data = data;
      font_ld_we = 1;
      @(negedge clk);
      font_ld_we = 0;
    end
  endtask

  // A byte write through the bridge: the guest's own path into text VRAM
  // (z486 -> the memory subsystem's TRAM select -> this bridge -> the array).
  task automatic cpu_write_byte(input [13:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      cpu_addr = addr;
      cpu_din = {4{data}};
      cpu_be = 4'b0001 << addr[1:0];
      cpu_write = 1'b1;
      cpu_line_read = 1'b0;
      cpu_valid = 1'b1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be = 0;
      while (u_bridge.state != 3'd0) @(negedge clk);
    end
  endtask

  task automatic cpu_read_byte(input [13:0] addr, output [7:0] data);
    begin
      @(negedge clk);
      cpu_addr = addr;
      cpu_din = 32'd0;
      cpu_be = 4'b0001 << addr[1:0];
      cpu_write = 1'b0;
      cpu_line_read = 1'b0;
      cpu_valid = 1'b1;
      while (!cpu_ready) @(negedge clk);
      while (!cpu_resp_valid) @(negedge clk);
      #1;
      data = cpu_dout[{addr[1:0], 3'b000} +: 8];
      @(negedge clk);
      cpu_valid = 0;
      cpu_be = 0;
      while (u_bridge.state != 3'd0) @(negedge clk);
    end
  endtask

  // The 8 dots of cell 0 of line 0, once the wrapped prefetch has loaded it.
  // All eight must carry the same colour: the glyph is all-ones, so the cell is
  // wholly foreground (or, under reverse, wholly background).
  task automatic sample_cell0(output [7:0] r, output [7:0] g, output [7:0] b);
    begin
      wait (u_gdc.u_crtc.hdot == 0 && u_gdc.u_crtc.vline == 0);
      r = 8'h00;
      g = 8'h00;
      b = 8'h00;
      for (k = 0; k < 8; k = k + 1) begin
        @(negedge clk);
        if (k == 0) begin
          r = r_out;
          g = g_out;
          b = b_out;
        end else if (r_out !== r || g_out !== g || b_out !== b)
          fail("the 8 dots of a text cell are not one colour");
      end
    end
  endtask

  // What the fixed text table must give for an attribute byte, expanded to the
  // 8-bit wires the framework sees (r_out = {R,R} and so on).
  function automatic [23:0] expect_rgb(input [7:0] attr);
    reg [2:0] idx;
    begin
      idx = attr[7:5];
      expect_rgb = 24'h000000;
      if (idx[1]) expect_rgb[23:16] = 8'hFF;  // R
      if (idx[2]) expect_rgb[15:8]  = 8'hFF;  // G
      if (idx[0]) expect_rgb[7:0]   = 8'hFF;  // B
    end
  endfunction

  // The memory-switch record the machine holds (the machine's probe results:
  // 0xA3FE2 + 4i = 48 05 0C 00 01 40 00 81).
  // The memory-switch record, as the machine currently reports it. Switch 5 was 0x40
  // in the 2026-09-12 capture and is 0x00 now: it is the keyboard-LED and shift-state
  // cell, SETUP rewrites it, and a SETUP change is
  // what moved it. The assertion below is that the attribute fill cannot change any of
  // these eight bytes -- which is the property under test -- so the values must be the
  // machine's, not historical.
  function automatic [7:0] expect_msw(input integer n);
    begin
      case (n)
        0: expect_msw = 8'h48;
        1: expect_msw = 8'h05;
        2: expect_msw = 8'h0C;
        3: expect_msw = 8'h00;
        4: expect_msw = 8'h01;
        5: expect_msw = 8'h00;
        6: expect_msw = 8'h00;
        default: expect_msw = 8'h81;
      endcase
    end
  endfunction

  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 0;
    rst_n = 1;

    // An all-ones 8x16 glyph for code 0x41 ('A'): every dot of the cell is
    // foreground, so the sampled colour is the text colour itself.
    for (i = 0; i < 8; i = i + 1)
      write_font(11'h208 + i[10:0], 16'hFFFF);
    cpu_write_byte(14'h0000, 8'h41);
    cpu_write_byte(14'h0001, 8'h00);
    cpu_write_byte(14'h2000, 8'hE1);
    write_io(8'h62, 8'h0D);   // BCTRL on; MODE FF1's reset state has DISP set

    // ---- 1. the byte the BIOS decides on, before anything writes text ----
    // The main BIOS reads 0xA3FEA and tests bit 6: set makes its console
    // attribute 0x81 (green), clear keeps 0xE1 (white).
    cpu_read_byte(14'h3FEA, value);
    if (value !== 8'h0C)
      fail("cold memory switch 3 is not the machine's 0x0C through the byte path");
    if (value[6])
      fail("cold memory switch 3 has bit 6 set: the BIOS would pick green");

    // ---- 2. text colour is the attribute, index by index, in both palettes ----
    for (pass = 0; pass < 3; pass = pass + 1) begin
      for (i = 0; i < 8; i = i + 1) begin
        cpu_write_byte(14'h2000, 8'h01 | (i[7:0] << 5));
        sample_cell0(sr, sg, sb);
        rgb = {sr, sg, sb};
        want = expect_rgb(8'h01 | (i[7:0] << 5));
        if (rgb !== want) begin
          $display("FAIL: attribute %02x drew %06x, the text table says %06x (pass %0d)",
                   8'h01 | (i[7:0] << 5), rgb, want, pass);
          errors = errors + 1;
        end
      end
      // visible bit clear draws nothing, whatever the colour bits say
      cpu_write_byte(14'h2000, 8'hE0);
      sample_cell0(sr, sg, sb);
      rgb = {sr, sg, sb};
      if (rgb !== 24'h000000) begin
        $display("FAIL: attribute E0 (colours, visible bit clear) drew %06x (pass %0d)", rgb, pass);
        errors = errors + 1;
      end
      // reverse with an all-ones glyph must show the background, not a colour
      cpu_write_byte(14'h2000, 8'hE5);
      sample_cell0(sr, sg, sb);
      rgb = {sr, sg, sb};
      if (rgb !== 24'h000000) begin
        $display("FAIL: attribute E5 (reverse) drew %06x, not the background (pass %0d)", rgb, pass);
        errors = errors + 1;
      end

      // Between the passes the graphics palette is rewritten through the only
      // ports that can do it: 0x6A num 0 selects 16-colour (analogue
      // index + components) or 8-colour (the four digital bytes), and
      // 0xA8/0xAA/0xAC/0xAE carry the data. Text colour must not move.
      if (pass == 0) begin
        write_io(8'h6A, 8'h01);            // 16-colour on
        for (i = 0; i < 16; i = i + 1) begin
          write_io(8'hA8, i[7:0]);
          write_io(8'hAA, 8'h07);
          write_io(8'hAC, 8'h07);
          write_io(8'hAE, 8'h07);
        end
      end else if (pass == 1) begin
        write_io(8'h6A, 8'h00);            // 8-colour digital
        write_io(8'hA8, 8'hFF);
        write_io(8'hAA, 8'hFF);
        write_io(8'hAC, 8'hFF);
        write_io(8'hAE, 8'hFF);
      end
    end
    cpu_write_byte(14'h2000, 8'hE1);

    // ---- 3. the guest's attribute fill must not eat the switch record ----
    // The BIOS's and DOS's clear walks the attribute plane at 0xA2000 with
    // stride 2, the switch cells included. On the machine those eight bytes are
    // protected; the fill reaches everything else in the tail, which is why the
    // machine's own 0xA3FE0/0xA3FE4 read 0xE1 while 0xA3FE2 keeps 0x48.
    for (i = 0; i < 4096; i = i + 1)
      cpu_write_byte(14'h2000 + {i[11:0], 1'b0}, 8'hE1);
    cpu_read_byte(14'h2000, value);
    if (value !== 8'hE1)
      fail("the attribute fill did not land on a plain attribute cell");
    cpu_read_byte(14'h3FE0, value);
    if (value !== 8'hE1)
      fail("the fill did not reach 0xA3FE0, the switch cells' unprotected neighbour");
    cpu_read_byte(14'h3FE4, value);
    if (value !== 8'hE1)
      fail("the fill did not reach 0xA3FE4");
    for (i = 0; i < 8; i = i + 1) begin
      cpu_read_byte(14'h3FE2 + (i[13:0] << 2), value);
      if (value !== expect_msw(i)) begin
        $display("FAIL: memory switch %0d read %02x after the attribute fill, the machine holds %02x",
                 i, value, expect_msw(i));
        errors = errors + 1;
      end
    end
    // The BIOS's own decision, after the fill: bit 6 clear is white.
    cpu_read_byte(14'h3FEA, value);
    if (value[6])
      fail("after the attribute fill the BIOS would read bit 6 set and draw the whole screen green");

    // ---- 4. the protect is an enable, not a wall ----
    write_io(8'h68, 8'h0D);              // MODE FF1 bit 6: switch write enable
    cpu_write_byte(14'h3FEA, 8'h4C);     // SETUP flipping switch 3 to green
    cpu_read_byte(14'h3FEA, value);
    if (value !== 8'h4C)
      fail("switch 3 could not be written with MODE FF1 bit 6 set");
    if (!value[6])
      fail("the written switch byte lost its bit 6");
    write_io(8'h68, 8'h0C);              // write disable again
    cpu_write_byte(14'h3FEA, 8'h0C);
    cpu_read_byte(14'h3FEA, value);
    if (value !== 8'h4C)
      fail("switch 3 changed while the write enable was clear");
    // Put the machine's record back, through the enable the ITF uses.
    write_io(8'h68, 8'h0D);
    cpu_write_byte(14'h3FEA, 8'h0C);
    write_io(8'h68, 8'h0C);
    cpu_read_byte(14'h3FEA, value);
    if (value !== 8'h0C)
      fail("switch 3 was not restored to the machine's 0x0C");

    // ---- 5. the pixels are faithful to whatever attribute they are given ----
    // If someone's screenshot is green, this is the mechanism and it is the same
    // on the machine: its own capture holds 0x81 in green cells. The fault would
    // be upstream of the pixels, in the byte that selects the attribute.
    cpu_write_byte(14'h2000, 8'h81);
    sample_cell0(sr, sg, sb);
    rgb = {sr, sg, sb};
    if (rgb !== 24'h00FF00) begin
      $display("FAIL: the BIOS's green console attribute 0x81 drew %06x", rgb);
      errors = errors + 1;
    end

  // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_TEXT_COLOUR: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_TEXT_COLOUR: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: twelve frames of the 848x440 timing is ~45 ms, so 200 ms
  // is ~4x headroom and still far tighter than the runner's wall clock.
  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_TEXT_COLOUR: TIMEOUT");
  end

endmodule

`default_nettype wire
