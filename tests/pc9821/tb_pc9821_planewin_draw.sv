`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PLANEWIN_DRAW: a FULL-SCREEN multi-plane picture drawn through the GVRAM plane windows (0xA8000-0xBFFFF) is asserted BY VALUE at every plane byte, so a store that lands the WRONG WORD in a few columns shows up as a horizontal stripe from elsewhere in the picture. Every shape the games issue is driven: plane-major and row-major multi-plane draws, the raster's flush interleaved per row, all four planes written to the SAME columns, a second pass over the picture, the `or es:[di],ax` read-modify-write composite, a 32-bit plane store (the four-byte width), and the graphics library's own `rep movsw` whole-plane stream at consecutive offsets. The check is a software model compared after a raster flush.
//
// WHY THIS EXISTS. The existing value benches draw at most one 16x16 sprite (tb_pc9821_sprite) or a single line (tb_pc9821_gvram_combine). The word-keyed write-combining buffer holds EIGHT words and a full-screen picture walks rows 80 words apart, so only a full-screen walk cycles the buffer enough to expose an eviction/fill slot that lands a word from another row, and only a streamed whole-plane walk reaches the row and plane ends.
//
// The check is a plain software model: every plane byte the store writes is recorded in `exp_mem` (with `expw`/`exp_col` for the streamed phases) and the picture is read back and compared. The read-back is preceded by a raster tick so the write-combining buffer has drained (its words are only visible in SDRAM after a flush).

`default_nettype none

module tb_pc9821_planewin_draw;
  localparam integer FREQ     = 50_000_000;
  localparam integer CYCLE_NS = 20;
  localparam [31:0]  GVRAM_BASE = 32'h0300_0000;

  localparam integer ROWS = 120;    // > 8 rows so the 8-slot WCB cycles many times
  localparam integer COLS = 80;     // one plane row = 80 bytes = 40 16-bit words

  reg clk = 0;
  always #(CYCLE_NS/2) clk = ~clk;
  reg reset = 1;

  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ==== DUT ====
  // ==== DUT ====
  reg        access_page = 1'b0;
  reg  [1:0] win_plane = 2'd0;
  reg [14:0] win_offset = 15'd0;
  reg [31:0] cpu_din = 32'd0;
  reg  [3:0] cpu_be = 4'hF;
  reg        cpu_line_read = 1'b0;
  reg        cpu_valid = 1'b0, cpu_write = 1'b0;
  wire [31:0]  cpu_dout;
  wire [31:0] cpu_line_word;
  wire         cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  reg        grcg_we = 1'b0;
  reg  [7:0] grcg_addr = 8'd0, grcg_din = 8'd0;

  reg        egc_gate = 1'b0;
  reg [15:0] egc_access = 16'hFFFF, egc_fgbg = 16'd0, egc_ope = 16'd0,
             egc_fg = 16'd0, egc_mask = 16'hFFFF, egc_bg = 16'd0,
             egc_sft = 16'd0, egc_leng = 16'd0;
  reg        egc_shift_we = 1'b0;

  reg        scan_enable = 1'b0, scan_line_tick = 1'b0, scan_page = 1'b0;
  reg [14:0] scan_line_base = 15'd0;
  reg  [6:0] line_rd_addr = 7'd0;
  reg        line_rd_sel = 1'b0;
  wire [31:0] line_data;
  wire        line_sel, line_ready;


  pc9821_gvram_dut dut (
      .clk(clk), .reset(reset),
      .access_page(access_page),
      .win_plane(win_plane), .win_offset(win_offset),
      .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_line_read(cpu_line_read),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_dout(cpu_dout), .cpu_line_word(cpu_line_word),
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_word_valid(cpu_line_word_valid),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din),
      .egc_gate(egc_gate), .egc_access(egc_access), .egc_fgbg(egc_fgbg),
      .egc_ope(egc_ope), .egc_fg(egc_fg), .egc_mask(egc_mask),
      .egc_bg(egc_bg), .egc_sft(egc_sft), .egc_leng(egc_leng),
      .egc_shift_we(egc_shift_we),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .scan_line_base(scan_line_base),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready));

  // ==== THE MODEL ====
  // exp_mem[plane][row][col] = the byte the image draw should leave in that plane byte. The
  // marker is a function of ALL THREE so a store that lands another row's or column's word is
  // visible as a value that decodes to a different (row, col).
  reg [7:0] exp_mem [0:3][0:ROWS-1][0:COLS-1];
  function automatic [7:0] marker(input integer plane, input integer row, input integer col);
    begin
      marker = 8'(((row * 37) + (plane * 91) + col) & 8'hFF);
    end
  endfunction

  // ==== CHECKS ====
  integer errors = 0;
  integer checks = 0;
  task automatic fail(input [8*200-1:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  // A raster line tick with the scanout enabled: sets flush_pending, so the WCB writes its dirty
  // words back and the SDRAM mirror is current. Wait for the flush to drain.
  task automatic flush_now;
    begin
      @(negedge clk); scan_enable = 1'b1; scan_line_tick = 1'b1;
      @(negedge clk); scan_line_tick = 1'b0;
      while (1'b0) @(posedge clk);
      repeat (4) @(posedge clk);
      scan_enable = 1'b0;
    end
  endtask

  // ==== THE PLANE-WINDOW STIMULUS ====
  // A 16-bit plane store at plane offset `off` (even), value `v` split across the two columns.
  task automatic pw16(input [1:0] plane, input [14:0] off, input [15:0] v);
    begin
      @(negedge clk);
      access_page = 1'b0;
      win_plane  = plane;
      win_offset = off;
      cpu_din    = off[1] ? {v, 16'd0} : {16'd0, v};
      cpu_be     = off[1] ? 4'b1100 : 4'b0011;
      cpu_write  = 1'b1;
      cpu_valid  = 1'b1;
      @(posedge clk); #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'hF;
      while (dut.u_arb.cs != 3'd0) @(posedge clk);
    end
  endtask

  // A 16-bit plane load at plane offset `off` (even).
  task automatic pr16(input [1:0] plane, input [14:0] off, output [15:0] v);
    reg [31:0] d;
    begin
      @(negedge clk);
      access_page = 1'b0;
      win_plane  = plane;
      win_offset = off;
      cpu_be     = off[1] ? 4'b1100 : 4'b0011;
      cpu_write  = 1'b0;
      cpu_valid  = 1'b1;
      @(posedge clk); #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      @(negedge clk);
      cpu_valid = 1'b0; cpu_be = 4'hF;
      #1;
      while (!cpu_resp_valid) begin @(posedge clk); #1; end
      d = cpu_dout;
      @(negedge clk);
      while (dut.u_arb.cs != 3'd0) @(posedge clk);
      v = off[1] ? d[31:16] : d[15:0];
    end
  endtask

  // Draw one (row, plane, column-pair) word and record it in the model.
  task automatic draw_word(input integer plane, input integer row, input integer cpair);
    reg [7:0] b0, b1;
    begin
      b0 = marker(plane, row, cpair * 2);
      b1 = marker(plane, row, cpair * 2 + 1);
      exp_mem[plane][row][cpair*2]     = b0;
      exp_mem[plane][row][cpair*2 + 1] = b1;
      pw16(plane[1:0], 15'((row * COLS) + cpair * 2), {b1, b0});
    end
  endtask

  // Read the whole picture back (after a flush) and assert every byte.
  task automatic verify(input [8*200-1:0] what);
    integer r, p, c;
    reg [7:0] got;
    reg [15:0] w;
    reg [31:0] bad;
    begin
      flush_now;
      bad = 0;
      for (p = 0; p < 4; p = p + 1) begin
        for (r = 0; r < ROWS; r = r + 1) begin
          for (c = 0; c < COLS; c = c + 2) begin
            pr16(p[1:0], 15'((r * COLS) + c), w);
            got = w[7:0];
            checks = checks + 1;
            if (got !== exp_mem[p][r][c]) begin
              if (bad < 4)
                $display("FAIL %0s: plane %0d row %0d col %0d = %02x, expected %02x",
                         what, p, r, c, got, exp_mem[p][r][c]);
              bad = bad + 1;
            end
            got = w[15:8];
            checks = checks + 1;
            if (got !== exp_mem[p][r][c+1]) begin
              if (bad < 4)
                $display("FAIL %0s: plane %0d row %0d col %0d = %02x, expected %02x",
                         what, p, r, c+1, got, exp_mem[p][r][c+1]);
              bad = bad + 1;
            end
          end
        end
      end
      if (bad != 0) fail(what);
      else $display("NOTE planewin_draw: %0s verified %0d plane bytes, 0 mismatches", what, checks);
    end
  endtask

  // Clear the picture to a known value and the model with it.
  task automatic clear_all(input [7:0] v);
    integer r, p, c;
    begin
      for (p = 0; p < 4; p = p + 1)
        for (r = 0; r < ROWS; r = r + 1)
          for (c = 0; c < COLS; c = c + 2) begin
            pw16(p[1:0], 15'((r * COLS) + c), {v, v});
            exp_mem[p][r][c]     = v;
            exp_mem[p][r][c + 1] = v;
          end
      flush_now;
    end
  endtask

  // ==== PHASE L: the game's actual shape ====
  // Rusty's graphics library (GRPEGC.COM) writes a whole plane with `rep movsw` into segment
  // 0xA800/0xB000/0xB800/0xE000: 16-bit stores at CONSECUTIVE plane offsets 0..0x7FFE, back to
  // back, no CPU gap between them. A full-screen picture IS one whole 32 KiB plane per plane of
  // the image, so this phase streams all four planes linearly and records a value that is
  // unique per (plane, word index), so a wrong word from any other offset or plane shows up.
  reg [15:0] expw [0:3][0:16383];
  function automatic [15:0] linmark(input integer plane, input integer k);
    begin
      // k*0x9E37 is a bijection mod 2^16 (the multiplier is odd), so a different k always
      // yields a different word, and the plane term separates the planes.
      linmark = 16'((k * 16'h9E37) + (plane * 16'h1234));
    end
  endfunction

  // A LINEAR plane stream: present the access, wait for the accept, and immediately present the
  // next -- cpu_valid stays high the whole way, exactly as a `rep movsw` leaves it.
  task automatic stream_planes;
    integer plane, k;
    reg [15:0] v;
    begin
      cpu_write  = 1'b1;
      cpu_valid  = 1'b1;
      cpu_be     = 4'b0011;
      win_offset = 15'd0;
      cpu_din    = {16'd0, linmark(0, 0)};
      win_plane  = 2'd0;
      for (plane = 0; plane < 4; plane = plane + 1) begin
        win_plane = plane[1:0];
        for (k = 0; k < 16384; k = k + 1) begin
          v = linmark(plane, k);
          expw[plane][k] = v;
          win_offset = 15'(k * 2);
          // off[1] rides the byte enables exactly as z486 presents it: an even 16-bit store on
          // lanes 2:3 carries its two bytes in the dword's HIGH half.
          cpu_din    = win_offset[1] ? {v, 16'd0} : {16'd0, v};
          cpu_be     = win_offset[1] ? 4'b1100 : 4'b0011;
          @(posedge clk);
          while (!cpu_ready) @(posedge clk);
        end
      end
      cpu_valid = 1'b0;
      cpu_write = 1'b0;
      cpu_be    = 4'hF;
    end
  endtask

  task automatic verify_planes(input [8*200-1:0] what);
    integer plane, k;
    reg [15:0] got;
    reg [31:0] bad;
    begin
      flush_now;
      bad = 0;
      for (plane = 0; plane < 4; plane = plane + 1)
        for (k = 0; k < 16384; k = k + 1) begin
          pr16(plane[1:0], 15'(k * 2), got);
          checks = checks + 1;
          if (got !== expw[plane][k]) begin
            if (bad < 4)
              $display("FAIL %0s: plane %0d word %0d = %04x, expected %04x",
                       what, plane, k, got, expw[plane][k]);
            bad = bad + 1;
          end
        end
      if (bad != 0) fail(what);
      else $display("NOTE planewin_draw: %0s verified %0d words, 0 mismatches", what, checks);
    end
  endtask

  // ==== PHASE R: the game's `or es:[di],ax` composite ====
  // GRPEGC.COM's sprite/tile blit is `lodsw` (the source word from RAM) then `or es:[di],ax`
  // then `add di,bx` with bx = 0x50: a 16-bit READ-MODIFY-WRITE of the destination word, walking
  // rows 80 bytes apart. The read half is what the plain walk's fill serves, so this is the shape
  // a fill/forward bug would show in and a write-only bench would miss.
  task automatic or_word(input integer plane, input integer row, input integer cpair);
    reg [15:0] got, src, want;
    reg [14:0] off;
    begin
      off  = 15'((row * COLS) + cpair * 2);
      src  = {marker(plane, row, cpair*2+1), marker(plane, row, cpair*2)};
      pr16(plane[1:0], off, got);
      want = got | src;
      exp_mem[plane][row][cpair*2]     = want[7:0];
      exp_mem[plane][row][cpair*2 + 1] = want[15:8];
      pw16(plane[1:0], off, want);
    end
  endtask

  // ==== PHASE W: a 32-bit plane store ====
  // A 32-bit plane store covers FOUR consecutive columns (the four byte lanes of the dword), so a
  // store that lands at the wrong base shows as a ~4-pixel horizontal strip - the width
  // observed. Streamed back to back like the game's `rep stosd`.
  function automatic [7:0] cm(input integer plane, input integer col);
    begin
      cm = 8'(((col * 37) + (plane * 91)) & 8'hFF);
    end
  endfunction
  reg [7:0] exp_col [0:3][0:32767];

  task automatic stream_dwords;
    integer plane, j;
    reg [31:0] dv;
    begin
      cpu_write = 1'b1;
      cpu_valid = 1'b1;
      cpu_be    = 4'hF;
      for (plane = 0; plane < 4; plane = plane + 1) begin
        win_plane = plane[1:0];
        for (j = 0; j < 8192; j = j + 1) begin
          dv = {cm(plane, j*4+3), cm(plane, j*4+2), cm(plane, j*4+1), cm(plane, j*4+0)};
          exp_col[plane][j*4+0] = cm(plane, j*4+0);
          exp_col[plane][j*4+1] = cm(plane, j*4+1);
          exp_col[plane][j*4+2] = cm(plane, j*4+2);
          exp_col[plane][j*4+3] = cm(plane, j*4+3);
          win_offset = 15'(j * 4);
          cpu_din    = dv;
          @(posedge clk);
          while (!cpu_ready) @(posedge clk);
        end
      end
      cpu_valid = 1'b0;
      cpu_write = 1'b0;
      cpu_be    = 4'hF;
    end
  endtask

  task automatic verify_dwords(input [8*200-1:0] what);
    integer plane, j;
    reg [15:0] got;
    reg [31:0] bad;
    begin
      flush_now;
      bad = 0;
      for (plane = 0; plane < 4; plane = plane + 1)
        for (j = 0; j < 8192; j = j + 1) begin
          pr16(plane[1:0], 15'(j * 4), got);
          checks = checks + 1;
          if (got !== {exp_col[plane][j*4+1], exp_col[plane][j*4]}) begin
            if (bad < 4)
              $display("FAIL %0s: plane %0d cols %0d/%0d = %04x, expected %04x",
                       what, plane, j*4, j*4+1, got, {exp_col[plane][j*4+1], exp_col[plane][j*4]});
            bad = bad + 1;
          end
          pr16(plane[1:0], 15'(j * 4 + 2), got);
          checks = checks + 1;
          if (got !== {exp_col[plane][j*4+3], exp_col[plane][j*4+2]}) begin
            if (bad < 4)
              $display("FAIL %0s: plane %0d cols %0d/%0d = %04x, expected %04x",
                       what, plane, j*4+2, j*4+3, got, {exp_col[plane][j*4+3], exp_col[plane][j*4+2]});
            bad = bad + 1;
          end
        end
      if (bad != 0) fail(what);
      else $display("NOTE planewin_draw: %0s verified %0d dwords, 0 mismatches", what, checks);
    end
  endtask

  // ==== PHASE S: scroll the plane, so the corruption is pinned to the WRITTEN data ====
  // The observed strips FOLLOW THE PLANE when the screen scrolls, so the wrong pixels are in the
  // GVRAM itself, not in the display path. The scroll is a same-plane overlapping copy (a
  // `movsw` walk with the source 80 bytes ahead of the destination, i.e. one row up): the copy
  // READS a word the plane already holds and WRITES it 40 words lower, which is the read-after-
  // write forwarding the buffer owes and the shape a mis-invalidated or mis-forwarded word shows
  // in. After the scroll every row must equal the row above it before the copy.
  task automatic scroll_up_one_row;
    integer plane, i;
    reg [15:0] v;
    begin
      for (plane = 0; plane < 4; plane = plane + 1)
        for (i = 0; i < (ROWS - 1) * 40; i = i + 1) begin
          pr16(plane[1:0], 15'((i + 40) * 2), v);
          pw16(plane[1:0], 15'(i * 2), v);
        end
    end
  endtask

  integer r, p, c, i;
  reg [15:0] w;

  initial begin
    reset  = 1'b1;
    repeat (8) @(posedge clk);
    i = 0;
    repeat (20) @(posedge clk);
    reset = 1'b0;
    repeat (20) @(posedge clk);

    $display("NOTE planewin_draw: picture = %0d rows x %0d columns x 4 planes, 16-bit plane stores",
             ROWS, COLS);

    // ---- PHASE A: plane-major. Each plane's whole picture, then the next plane. This is the
    // "drawn on top of each other" shape: plane p+1's stores revisit every word plane p wrote. ----
    for (p = 0; p < 4; p = p + 1)
      for (r = 0; r < ROWS; r = r + 1)
        for (c = 0; c < COLS; c = c + 2)
          draw_word(p, r, c / 2);
    verify("A plane-major full-screen draw");

    // ---- PHASE B: row-major. For each row, all four planes of the row, then the next row. The
    // four plane stores to a row's word land back-to-back, which is the coalescer's merge case. ----
    for (r = 0; r < ROWS; r = r + 1)
      for (p = 0; p < 4; p = p + 1)
        for (c = 0; c < COLS; c = c + 2)
          draw_word(p, r, c / 2);
    verify("B row-major full-screen draw");

    // ---- PHASE C: the same draw with a raster flush every row, which drains the WCB mid-picture
    // and forces the next row's fills through a freshly emptied buffer. ----
    for (r = 0; r < ROWS; r = r + 1) begin
      for (p = 0; p < 4; p = p + 1)
        for (c = 0; c < COLS; c = c + 2)
          draw_word(p, r, c / 2);
      flush_now;
    end
    verify("C flush-per-row full-screen draw");

    // ---- PHASE D: overlay. All four planes written to the SAME columns with DIFFERENT values,
    // one word at a time, so every store must supersede the previous plane's byte in the same
    // word. Read back per plane. ----
    for (r = 0; r < ROWS; r = r + 1)
      for (c = 0; c < COLS; c = c + 2)
        for (p = 0; p < 4; p = p + 1)
          draw_word(p, r, c / 2);
    verify("D per-column four-plane overlay");

    // ---- PHASE E: a second pass over the whole picture, so every word was already held (or
    // already written back) when the store arrives ----
    clear_all(8'h00);
    for (p = 0; p < 4; p = p + 1)
      for (r = 0; r < ROWS; r = r + 1)
        for (c = 0; c < COLS; c = c + 2)
          draw_word(p, r, c / 2);
    verify("E second full-screen pass");

    $display("NOTE planewin_draw: %0d byte checks total, %0d error(s)", checks, errors);

    // ---- PHASE R: the game's own read-modify-write composite, verified ----
    clear_all(8'h00);
    for (r = 0; r < ROWS; r = r + 1)
      for (p = 0; p < 4; p = p + 1)
        for (c = 0; c < COLS; c = c + 2)
          or_word(p, r, c / 2);
    verify("R read-modify-write composite");

    // ---- PHASE S: scroll the picture one row up and check the pixels moved WITH the plane ----
    clear_all(8'h00);
    for (r = 0; r < ROWS; r = r + 1)
      for (p = 0; p < 4; p = p + 1)
        for (c = 0; c < COLS; c = c + 2)
          draw_word(p, r, c / 2);
    flush_now;
    scroll_up_one_row;
    flush_now;
    begin : scroll_check
      reg [15:0] got;
      integer bad;
      bad = 0;
      for (p = 0; p < 4; p = p + 1)
        for (r = 0; r < ROWS - 1; r = r + 1)
          for (c = 0; c < COLS; c = c + 2) begin
            pr16(p[1:0], 15'((r * COLS) + c), got);
            checks = checks + 1;
            // row r after the scroll must be the marker of row r+1 before it
            if ((got[7:0] !== marker(p, r + 1, c)) ||
                (got[15:8] !== marker(p, r + 1, c + 1))) begin
              if (bad < 4)
                $display("FAIL S scroll: plane %0d row %0d col %0d = %04x, expected %02x%02x (row %0d's data)",
                         p, r, c, got, marker(p, r + 1, c + 1), marker(p, r + 1, c), r + 1);
              bad = bad + 1;
            end
          end
      if (bad != 0) fail("S scrolled picture");
      else $display("NOTE planewin_draw: S scrolled picture verified, pixels moved with the plane");
    end

    // ---- PHASE W: a 32-bit plane store, the ~4-pixel-strip width ----
    stream_dwords;
    verify_dwords("W 32-bit plane store stream");

    // ---- PHASE L: the game's real shape (GRPEGC.COM's `rep movsw` plane stream) ----
    stream_planes;
    verify_planes("L linear whole-plane stream");

    // ---- PHASE M: the same stream again, so every word is already held or already written ----
    stream_planes;
    verify_planes("M second linear plane stream");

    $display("NOTE planewin_draw: %0d checks total, %0d error(s)", checks, errors);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PLANEWIN_DRAW: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_PLANEWIN_DRAW: FAIL (%0d errors)", errors);
      $fatal(1, "TB_PC9821_PLANEWIN_DRAW: FAIL");
    end
  end

  initial begin
    #2_000_000_000;
    $fatal(1, "TB_PC9821_PLANEWIN_DRAW: FAIL (timed out)");
  end

endmodule

`default_nettype wire
