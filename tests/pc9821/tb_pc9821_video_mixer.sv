`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_VIDEO_MIXER:
// The graphics side of the scanout: the four planes fold to the 4-bit index {E,G,R,B} -- one bit per lane per dot, B bit 0, R bit 1, G bit 2, E bit 3, MSB first -- the palette reads that index out of the 16-entry analogue table or, in 8-colour digital mode, out of the pack the machine's own power-on bytes imply (0xA8/AA/AC/AE = 37/15/26/04 -> black, blue, red, magenta, green, cyan, yellow, white), a 256-colour index bypasses the fold into the 256-entry FULL-byte table (NP2kai pal_make9821 renders the bytes verbatim) whose registered read delays BOTH arms by one clk_sys in 256-colour mode only - the uniform one-dot delay, with the boundary capture still showing the old TEXT dot - while the 16-colour path moves not one dot (a 24-vector sweep against the closed-form old path), the 256-colour index is the full 8-bit byte (0x16 is not 0x06), and the 200-line odd-line gate is dropped in packed mode and kept in 16-colour mode, and the D4 compositor puts an opaque text dot over the graphics pixel, shows graphics under a transparent one, and changes its answer when the rule select is flipped.

// Both halves of this bench exist because of one decision: the design keeps the
// plane fold and the palette in SEPARATE modules (so PEGC's packed 256-colour
// mode can bypass the fold without a second datapath) and writes the
// compositor as ONE two-way priority mux behind a rule select, because the rule
// NP2kai implements is a model and not a measurement.
// The bench therefore drives the fold, the palette and the mixer independently
// and then asserts that the compositor's answer CHANGES when the select does.
//
// The analogue table is loaded through the CPU write port, exactly as pc9821_gdc_text
// drives it (a write reaches the table at once, so no commit follows it).
//
// Everything here is a synthetic vector list -- there is no photograph to take
// and none is needed: what a hardware probe settles is which rule the hardware
// uses, not what any rule computes. The mapping the default arm computes is
// NP2kai's, and the machine's own power-on digital palette bytes are the input
// that pins the digital table's channel order. The watchdog below is the bound.

`default_nettype none

module tb_pc9821_video_mixer;

  integer errors = 0;
  integer p, d, k;
  reg [11:0] c;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  // ==== DUT ====
  // The fold: one four-plane column word and one dot -> one palette index.
  reg  [31:0] column = 32'h0;
  reg  [2:0]  dot = 3'd0;
  wire [3:0]  fold_idx;
  pc9821_plane_fold u_fold (
      .column(column), .dot(dot), .idx(fold_idx)
  );

  // The palette on its own: index + colour mode + the table's write port -> {R,G,B}.
  reg  [7:0]  pal_idx = 8'h0;
  reg         pal_mode16 = 1'b1;
  reg  [31:0] pal_dig = 32'h0;
  reg         pwe = 1'b0;
  reg  [3:0]  pwid = 4'd0;
  reg  [1:0]  pwch = 2'd0;
  reg  [3:0]  pwdat = 4'd0;
  // The PEGC 256-colour table's write port and dot read (row 4).
  reg         p256_we = 1'b0;
  reg  [7:0]  p256_widx = 8'd0, p256_wdata = 8'd0;
  reg  [1:0]  p256_wchan = 2'd0;
  reg  [7:0]  pal_idx256 = 8'd0;
  wire [23:0] pal_colour256;
  wire [11:0] pal_colour;
  pc9821_gfx_palette u_pal (
      .clk(clk),
      .idx(pal_idx), .mode16(pal_mode16), .dig(pal_dig),
      .we(pwe), .widx(pwid), .wchan(pwch), .wdata(pwdat),
      .colour(pal_colour),
      .p256_we(p256_we), .p256_widx(p256_widx),
      .p256_wchan(p256_wchan), .p256_wdata(p256_wdata),
      .idx256(pal_idx256), .colour256(pal_colour256)
  );

  // The mixer: the pixel-timing view, the text plane's flags, the line buffer's
  // read port and the palette's write port -> the framework's r/g/b.
  reg  [9:0]  dot_x = 10'd0;
  reg         h_active = 1'b0, v_active = 1'b0;
  reg         text_opaque = 1'b0, text_cell = 1'b0;
  reg  [11:0] text_colour = 12'h0;
  reg  [31:0] line_data = 32'h0;
  reg         line_ready = 1'b0;
  reg         line_sel = 1'b0;
  wire [6:0]  line_rd_addr;
  wire        line_rd_sel;
  reg         fold_bypass = 1'b0;
  reg  [7:0]  packed_idx = 8'h0;
  reg  [1:0]  comp_rule = 2'b00;
  reg         grph_disp = 1'b0;
  reg         mwe = 1'b0;
  reg  [3:0]  mwid = 4'd0;
  reg  [1:0]  mwch = 2'd0;
  reg  [3:0]  mwdat = 4'd0;
  // The PEGC arm's inputs (row 4): the view select, the odd-line gate and the
  // mixer's own 256-colour write port.
  reg         mix_pegc_256 = 1'b0;
  reg         gfx_odd_line = 1'b0;
  reg         m256we = 1'b0;
  reg  [7:0]  m256wid = 8'd0, m256wdat = 8'd0;
  reg  [1:0]  m256wch = 2'd0;
  wire [7:0]  r_out, g_out, b_out;
  pc9821_video_mixer u_mix (
      .clk(clk),
      .dot_x(dot_x), .h_active(h_active), .v_active(v_active),
      .text_opaque(text_opaque), .text_cell(text_cell), .text_colour(text_colour),
      .line_data(line_data), .line_ready(line_ready), .line_sel(line_sel),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .pal_mode16(pal_mode16), .pal_dig(pal_dig),
      .pal_wr_en(mwe), .pal_wr_idx(mwid), .pal_wr_chan(mwch),
      .pal_wr_data(mwdat),
      .pegc_256(mix_pegc_256),
      .fold_bypass(fold_bypass), .packed_idx(packed_idx),
      .pal256_wr_en(m256we), .pal256_wr_idx(m256wid),
      .pal256_wr_chan(m256wch), .pal256_wr_data(m256wdat),
      .comp_rule(comp_rule), .grph_disp(grph_disp), .gfx_odd_line(gfx_odd_line),
      .r_out(r_out), .g_out(g_out), .b_out(b_out)
  );

  // Bound. The run block below has no wait, but a bench with no bound cannot be
  // told from a hung one.
  initial begin
    #1_000_000;
    $display("FAIL watchdog: the video mixer bench did not finish");
    $fatal(1, "timeout");
  end

  // ==== STIMULUS ====
  task automatic fail(input [8*96-1:0] message);
    begin
      $display("FAIL: %0s", message);
      errors = errors + 1;
    end
  endtask

  // The three bytes the framework sees for a {R,G,B} nibble triple: nibble
  // replication, {n,n}, not a linear scale (NP2kai anapal1[i] = i * 0x11).
  function automatic [23:0] expand(input [11:0] v);
    begin
      expand = { {v[11:8], v[11:8]}, {v[7:4], v[7:4]}, {v[3:0], v[3:0]} };
    end
  endfunction

  // The colour the palette module must produce for one index, as the bench's own
  // copy of the rule -- written independently of the DUT so the DUT cannot agree
  // with itself.
  function automatic [11:0] want_analogue(input [3:0] i);
    begin
      want_analogue = { i, 4'hF - i, i ^ 4'h5 };
    end
  endfunction

  // The machine's power-on digital bytes (probes/R10.TXT: 0xA8/AA/AC/AE =
  // 37/15/26/04) and the 8 colours NP2kai's pack expansion implies for them:
  // the three index bits are {G = bit2, R = bit1, B = bit0}.
  function automatic [11:0] want_digital(input [2:0] i);
    begin
      case (i)
        3'd0: want_digital = 12'h000;   // black   (0xAE high nibble)
        3'd1: want_digital = 12'h00F;   // blue    (0xAA high)
        3'd2: want_digital = 12'hF00;   // red     (0xAC high)
        3'd3: want_digital = 12'hF0F;   // magenta (0xA8 high)
        3'd4: want_digital = 12'h0F0;   // green   (0xAE low)
        3'd5: want_digital = 12'h0FF;   // cyan    (0xAA low)
        3'd6: want_digital = 12'hFF0;   // yellow  (0xAC low)
        default: want_digital = 12'hFFF; // white  (0xA8 low)
      endcase
    end
  endfunction

  // NP2kai's power-on analogue table -- `defanapal`, which this core seeds from
  // the ITF at itf.rom 0x042F (pc9821_gfx_palette's own power-on localparam).
  // NP2kai passes `pal>>8` to green, `pal>>4` to red and `pal` to blue, so the
  // packed entries decode as {R,G,B}: 1 = blue, 2 = red, 4 = green and 8 = the
  // first bright colour, so a single lit plane must land on its own primary and
  // the intensity plane on the bright bank.
  function automatic [11:0] defanapal(input [3:0] i);
    begin
      case (i)
        4'h0: defanapal = 12'h000;   // black
        4'h1: defanapal = 12'h007;   // blue        (index bit 0)
        4'h2: defanapal = 12'h700;   // red         (index bit 1)
        4'h3: defanapal = 12'h707;   // magenta
        4'h4: defanapal = 12'h070;   // green       (index bit 2)
        4'h5: defanapal = 12'h077;   // cyan
        4'h6: defanapal = 12'h770;   // yellow
        4'h7: defanapal = 12'h777;   // white
        4'h8: defanapal = 12'h444;   // dark grey   (intensity alone)
        4'h9: defanapal = 12'h00F;   // bright blue
        4'hA: defanapal = 12'hF00;   // bright red
        4'hB: defanapal = 12'hF0F;   // bright magenta
        4'hC: defanapal = 12'h0F0;   // bright green
        4'hD: defanapal = 12'h0FF;   // bright cyan
        4'hE: defanapal = 12'hFF0;   // bright yellow
        default: defanapal = 12'hFFF; // bright white
      endcase
    end
  endfunction

  // Check one pixel: the 24-bit value the framework must see.
  task automatic check_pixel(input [8*96-1:0] what, input [23:0] want);
    begin
      // The palette's output is REGISTERED, so a changed input needs a
      // clock edge before the framework's bytes can show it.
      @(posedge clk);
      #1;
      if ({r_out, g_out, b_out} !== want) begin
        $display("FAIL: %0s -> %02x%02x%02x, expected %06x",
                 what, r_out, g_out, b_out, want);
        errors = errors + 1;
      end
    end
  endtask

  // Load the palette's analogue table with `c` for every entry, through the write
  // port. `sel` picks which instance is loaded (0 = the
  // standalone palette, 1 = the mixer's internal one).
  task automatic load_table(input [11:0] v [0:15]);
    integer j;
    begin
      for (j = 0; j < 16; j = j + 1) begin
        @(negedge clk);
        pwe = 1'b1; pwch = 2'd1; pwid = j[3:0]; pwdat = v[j][11:8];   // R
        @(negedge clk);
        pwch = 2'd0; pwdat = v[j][7:4];                                // G
        @(negedge clk);
        pwch = 2'd2; pwdat = v[j][3:0];                                // B
        @(negedge clk);
        pwe = 1'b0;
      end
      @(negedge clk);
    end
  endtask

  task automatic load_mixer_table(input [11:0] v [0:15]);
    integer j;
    begin
      for (j = 0; j < 16; j = j + 1) begin
        @(negedge clk);
        mwe = 1'b1; mwch = 2'd1; mwid = j[3:0]; mwdat = v[j][11:8];
        @(negedge clk);
        mwch = 2'd0; mwdat = v[j][7:4];
        @(negedge clk);
        mwch = 2'd2; mwdat = v[j][3:0];
        @(negedge clk);
        mwe = 1'b0;
      end
      @(negedge clk);
    end
  endtask

  // ---- helpers for the PEGC arm (sections 8-9) ----
  // One 256-colour entry, through the mixer's own write port (full bytes).
  task automatic set256(input [7:0] e, input [7:0] r, input [7:0] g, input [7:0] b);
    begin
      @(negedge clk); m256we = 1'b1; m256wid = e; m256wch = 2'd1; m256wdat = r;
      @(negedge clk); m256wch = 2'd0; m256wdat = g;
      @(negedge clk); m256wch = 2'd2; m256wdat = b;
      @(negedge clk); m256we = 1'b0;
    end
  endtask

  // A sample INSIDE the current dot (after the driving edge, before the next
  // posedge): exactly what the framework's flops capture at that posedge.
  task automatic sample_pixel(input [8*96-1:0] what, input [23:0] want);
    begin
      #1;
      if ({r_out, g_out, b_out} !== want) begin
        $display("FAIL: %0s -> %02x%02x%02x, expected %06x",
                 what, r_out, g_out, b_out, want);
        errors = errors + 1;
      end
    end
  endtask

  // The OLD 16-colour path in closed form: fold -> power-on table -> compositor
  // -> nibble replicate, written from the bench's own reference functions so the
  // sweep compares the DUT against the RULE rather than against itself.
  function automatic [23:0] want_old_path(input [31:0] ld, input [2:0] dx,
                                          input to, input tc, input [11:0] tcol,
                                          input [1:0] rule, input gd);
    reg [3:0]  fidx;
    reg [11:0] gcol, p12;
    begin
      fidx = {ld[8*3 + 7 - dx], ld[8*2 + 7 - dx],
              ld[8*1 + 7 - dx], ld[8*0 + 7 - dx]};
      gcol = defanapal(fidx);
      // grph_shown = gd && line_ready && !rule[1] && !gfx_odd_line, with
      // line_ready = 1 and gfx_odd_line = 0 throughout the sweep.
      p12 = (rule[0] ? tc : to) ? tcol :
            ((gd && !rule[1]) ? gcol : 12'h000);
      want_old_path = { {p12[11:8], p12[11:8]},
                        {p12[7:4],  p12[7:4]},
                        {p12[3:0],  p12[3:0]} };
    end
  endfunction

  reg [11:0] tbl [0:15];

  // ==== CHECKS ====
  initial begin
    integer j;
    repeat (4) @(negedge clk);
    rst_n = 1;

    // ---------------------------------------------------------------
    // 1. The fold: one bit per lane per dot, {E,G,R,B} in bits 3..0.
    // ---------------------------------------------------------------
    // The column word is one byte per plane, MSB first, so dot d of plane p is
    // bit (7-d) of byte p. A single lit dot in plane p must therefore set index
    // bit p and nothing else -- which pins both the plane order and the dot
    // order, the two things a scanout can get wrong and still look plausible.
    for (p = 0; p < 4; p = p + 1)
      for (d = 0; d < 8; d = d + 1) begin
        column = 32'h0;
        column[8*p +: 8] = 8'h80 >> d;
        dot = d[2:0];
        #1;
        if (fold_idx !== (4'b0001 << p)) begin
          $display("FAIL: plane %0d dot %0d folded to %x, expected %x",
                   p, d, fold_idx, 4'b0001 << p);
          errors = errors + 1;
        end
      end

    // All four planes lit is the whole index; the order of the index bits is
    // B = bit 0, R = bit 1, G = bit 2, E = bit 3.
    column = 32'hFFFF_FFFF;
    dot = 3'd0;
    #1;
    if (fold_idx !== 4'hF) begin
      $display("FAIL: all planes lit folded to %x, expected f", fold_idx);
      errors = errors + 1;
    end
    // A mixed pattern at one dot: E|R = 1010 = a, at dot 3 (bit 4 of each byte).
    column = 32'h0;
    column[8*3 +: 8] = 8'h10;   // plane 3, dot 3
    column[8*1 +: 8] = 8'h10;   // plane 1, dot 3
    dot = 3'd3;
    #1;
    if (fold_idx !== 4'hA) begin
      $display("FAIL: E|R at dot 3 folded to %x, expected a", fold_idx);
      errors = errors + 1;
    end

    // ---------------------------------------------------------------
    // 2. The palette: the 16-entry analogue table, read by the 4-bit index.
    // ---------------------------------------------------------------
    // A distinctive value per entry per channel, so a swapped channel or a
    // wrong entry is visible rather than plausible.
    for (k = 0; k < 16; k = k + 1) tbl[k] = want_analogue(k[3:0]);
    load_table(tbl);
    pal_mode16 = 1'b1;
    for (k = 0; k < 16; k = k + 1) begin
      pal_idx = k[7:0];
      @(negedge clk);
      @(negedge clk);
      if (pal_colour !== want_analogue(k[3:0])) begin
        $display("FAIL: analogue entry %0d read %03x, expected %03x",
                 k, pal_colour, want_analogue(k[3:0]));
        errors = errors + 1;
      end
    end

    // The intensity plane is index bit 3, so entries 8..15 are the upper bank:
    // index 8 must read entry 8, not entry 0.
    if (want_analogue(4'h8) == want_analogue(4'h0)) begin
      fail("the bench's own table does not distinguish entry 8 from entry 0");
    end

    // ---------------------------------------------------------------
    // 3. The digital palette, from the machine's own power-on bytes.
    // ---------------------------------------------------------------
    pal_dig = {8'h37, 8'h15, 8'h26, 8'h04};   // 0xA8, 0xAA, 0xAC, 0xAE
    pal_mode16 = 1'b0;
    for (k = 0; k < 8; k = k + 1) begin
      pal_idx = k[7:0];
      @(negedge clk);
      @(negedge clk);
      if (pal_colour !== want_digital(k[2:0])) begin
        $display("FAIL: digital colour %0d read %03x, expected %03x",
                 k, pal_colour, want_digital(k[2:0]));
        errors = errors + 1;
      end
    end
    // ... and the digital table is NOT the analogue one: with mode16 set, the
    // same index reads the analogue registers.
    pal_mode16 = 1'b1;
    pal_idx = 8'h01;
    @(negedge clk);
    @(negedge clk);
    if (pal_colour === want_digital(3'd1)) begin
      fail("the analogue and digital reads returned the same colour");
    end

    // ---------------------------------------------------------------
    // 4. PEGC 256-colour bypasses the fold.
    // ---------------------------------------------------------------
    // The line buffer's word is all zero, so the fold's answer is index 0. A
    // packed pixel of 6 must reach the palette instead of the fold's 0 when the
    // bypass is on, and must NOT when it is off.
    line_data = 32'h0;
    fold_bypass = 1'b0;
    packed_idx = 8'h06;
    text_opaque = 1'b0; text_cell = 1'b0; text_colour = 12'h000;
    dot_x = 10'd0;
    h_active = 1'b1; v_active = 1'b1;
    line_ready = 1'b1; grph_disp = 1'b1;
    comp_rule = 2'b00;
    check_pixel("an unbypassed packed pixel must not reach the palette",
                expand(defanapal(4'h0)));
    fold_bypass = 1'b1;
    check_pixel("a 256-colour packed pixel must reach the palette in place of the fold",
                expand(defanapal(4'h6)));
    // The upper bits address PEGC's 256-entry table, which this core does not
    // build (no game in the set uses PEGC): only the low four bits resolve. This
    // assertion records that limit so implementing the table would be a
    // deliberate change rather than a surprise.
    packed_idx = 8'h16;
    check_pixel("the deferred PEGC bank bits must not change the 16-entry read",
                expand(defanapal(4'h6)));
    fold_bypass = 1'b0;

    // ---------------------------------------------------------------
    // 5. The fold order, pinned by the palette the machine seeds.
    // ---------------------------------------------------------------
    // The strongest available statement of the fold's bit order is not the
    // bench's own convention but NP2kai's power-on table: index 1 is blue, 2 is
    // red, 4 is green and 8 is the intensity bank, so each single lit plane must
    // reach its own primary and E alone must reach the dark-grey bank. The
    // machine's ITF seeds this same table (itf.rom 0x042F), and the mixer's own
    // palette - which starts at exactly that power-on table - answers it.
    pal_mode16 = 1'b1;
    fold_bypass = 1'b0;
    text_opaque = 1'b0; text_cell = 1'b0;
    grph_disp = 1'b1; line_ready = 1'b1;
    h_active = 1'b1; v_active = 1'b1;
    comp_rule = 2'b00;
    dot_x = 10'd0;
    for (p = 0; p < 4; p = p + 1) begin
      line_data = 32'h0;
      line_data[8*p +: 8] = 8'h80;      // plane p alone, dot 0
      @(posedge clk);
      #1;
      if ({r_out, g_out, b_out} !== expand(defanapal(4'b0001 << p))) begin
        $display("FAIL: plane %0d alone gave %02x%02x%02x, the table says %06x",
                 p, r_out, g_out, b_out, expand(defanapal(4'b0001 << p)));
        errors = errors + 1;
      end
    end
    // Blue + intensity: index 9, the bright blue, i.e. the intensity plane is
    // index bit 3 rather than another colour bit.
    line_data = 32'h0;
    line_data[8*0 +: 8] = 8'h80;
    line_data[8*3 +: 8] = 8'h80;
    @(posedge clk);
    #1;
    if ({r_out, g_out, b_out} !== expand(defanapal(4'h9))) begin
      $display("FAIL: B|E gave %02x%02x%02x, the table says %06x",
               r_out, g_out, b_out, expand(defanapal(4'h9)));
      errors = errors + 1;
    end

    // ---------------------------------------------------------------
    // 6. The compositor: one two-way priority mux, and its select.
    // ---------------------------------------------------------------
    // Graphics: every plane lit at every dot -> index 15 -> bright white in the
    // power-on table.
    line_data = 32'hFFFF_FFFF;
    text_colour = 12'hABC;          // R = a, G = b, B = c
    grph_disp = 1'b1;
    line_ready = 1'b1;
    h_active = 1'b1; v_active = 1'b1;

    // Default rule (NP2kai p_2): an opaque text dot wins.
    comp_rule = 2'b00;
    text_opaque = 1'b1; text_cell = 1'b1;
    check_pixel("an opaque text dot must win over the graphics pixel",
                expand(12'hABC));
    // ... and a transparent dot shows graphics even when the cell is visible:
    // that is exactly the difference between the two rules, so it is the vector
    // the select below has to change.
    text_opaque = 1'b0; text_cell = 1'b1;
    check_pixel("under the NP2kai rule a transparent dot shows graphics",
                expand(defanapal(4'hF)));

    // The flipped rule select (cell-opaque): the same transparent dot in a
    // visible cell is now opaque in the attribute colour.
    comp_rule = 2'b01;
    check_pixel("flipping the rule select must make a visible cell opaque",
                expand(12'hABC));
    text_opaque = 1'b1; text_cell = 1'b1;
    check_pixel("under the cell rule a visible cell with a glyph is still opaque",
                expand(12'hABC));
    text_opaque = 1'b0; text_cell = 1'b0;
    check_pixel("under the cell rule an invisible cell shows graphics",
                expand(defanapal(4'hF)));

    // The third arm (text-only, NP2kai's p_1): graphics are not composited at
    // all, so a transparent dot is background rather than a graphics pixel.
    comp_rule = 2'b10;
    text_opaque = 1'b0; text_cell = 1'b0;
    check_pixel("the text-only arm must not show the graphics plane",
                24'h000000);
    text_opaque = 1'b1;
    check_pixel("the text-only arm still shows the text plane", expand(12'hABC));

    // Graphics display off: the carried P2 -- this core paints black under the
    // text rather than NP2kai's palette entry 0.
    comp_rule = 2'b00;
    text_opaque = 1'b0;
    grph_disp = 1'b0;
    check_pixel("graphics display off must blank the graphics plane",
                24'h000000);
    grph_disp = 1'b1;

    // Outside the active area the output is black whatever the two planes say.
    h_active = 1'b0;
    check_pixel("outside the active dots the output must be blanked",
                24'h000000);
    h_active = 1'b1;
    v_active = 1'b0;
    check_pixel("outside the active lines the output must be blanked",
                24'h000000);
    v_active = 1'b1;

    // ---------------------------------------------------------------
    // 7. The line-buffer read port, the seam with pc9821_gvram.
    // ---------------------------------------------------------------
    // The buffer's read is REGISTERED, so the word for a column must be presented
    // for the WHOLE of that column: a dot is 2.375 clk_sys, so the read has
    // settled before the dot enable samples the column's FIRST dot. The
    // sequencer used to prefetch column c+1 on column c's last dot, which served
    // that dot from the next column's word -- a static error every 8 pixels.
    h_active = 1'b1;
    line_sel = 1'b0;
    dot_x = 10'd299;                 // 8*37 + 3: mid-column 37
    #1;
    if (line_rd_addr !== 7'd37) begin
      $display("FAIL: mid-column read address %0d, expected 37", line_rd_addr);
      errors = errors + 1;
    end
    if (line_rd_sel !== 1'b0) begin
      fail("the read buffer select did not follow the line buffer's own select");
    end
    line_sel = 1'b1;
    #1;
    if (line_rd_sel !== 1'b1) begin
      fail("the read buffer select did not follow the line buffer's own select");
    end
    dot_x = 10'd303;                 // 8*37 + 7: last dot of column 37
    #1;
    if (line_rd_addr !== 7'd37) begin
      $display("FAIL: the last dot of a column must still read ITS column (got %0d)",
               line_rd_addr);
      errors = errors + 1;
    end
    dot_x = 10'd639;                 // last dot of column 79: still column 79
    #1;
    if (line_rd_addr !== 7'd79) begin
      $display("FAIL: the last dot of the last column read address %0d, expected 79",
               line_rd_addr);
      errors = errors + 1;
    end
    h_active = 1'b0;
    dot_x = 10'd700;
    #1;
    if (line_rd_addr !== 7'd0) begin
      fail("the read address must be parked at column 0 outside the active dots");
    end

    // ---------------------------------------------------------------
    // 8. THE PEGC 256-COLOUR ARM (pegc-scope-REPORT.md 4 row 4).
    // ---------------------------------------------------------------
    // The table stores FULL bytes per channel and the dot path renders them
    // verbatim (NP2kai pal_make9821 `p[i].p.g = pal[i*4+0]`, vram/palettes.c;
    // MAME sets_pen_color with the full bytes). The index is the FULL 8-bit
    // packed byte - the 16-entry/nibble form would alias 0x16 onto 0x06.
    set256(8'h06, 8'h34, 8'h12, 8'h56);
    set256(8'h16, 8'hAA, 8'hBB, 8'hCC);
    // enter the arm: the view select, the fold bypassed, index 0x06
    mix_pegc_256 = 1'b1;
    fold_bypass = 1'b1;
    packed_idx = 8'h06;
    grph_disp = 1'b1; line_ready = 1'b1;
    h_active = 1'b1; v_active = 1'b1;
    text_opaque = 1'b0; text_cell = 1'b0; text_colour = 12'h000;
    comp_rule = 2'b00;
    // The read is REGISTERED (the table cannot be read asynchronously - the
    // 276007 refusal), so one clk after the index is presented the colour is out.
    @(negedge clk);
    check_pixel("the 256-colour arm renders FULL bytes (NP2kai pal_make9821)",
                24'h341256);
    packed_idx = 8'h16;
    @(negedge clk);
    check_pixel("the 256-colour index is the FULL byte (0x16 is not 0x06)",
                24'hAABBCC);
    packed_idx = 8'h06;

    // The uniform one-dot delay: in 256-colour mode BOTH arms carry the one
    // clk_sys register the palette read takes, so the framework's capture AT the
    // switching edge (the pre-edge wires) must still show the old TEXT dot - not
    // the old graphics colour under the new text flag. Without the text delay the
    // same instant shows the old GRAPHICS colour (G0) instead of T0: FAIL-FIRST
    // for the delay. The sample is taken inside the dot (after the input switch,
    // before the next posedge), which is exactly what the framework's flops see.
    text_opaque = 1'b1; text_colour = 12'h777;   // T0
    @(negedge clk); @(negedge clk);              // both delayed arms now T0
    check_pixel("uniform delay: the text arm settles", 24'h777777);
    // the simultaneous switch: text off, new text colour, new packed index
    @(negedge clk);
    text_opaque = 1'b0; text_colour = 12'h123;   // T1 (unused by the output)
    packed_idx = 8'h16;                          // G1 = AABBCC
    sample_pixel("uniform delay: the boundary capture still shows the old TEXT dot",
                 24'h777777);
    @(negedge clk);
    sample_pixel("uniform delay: the next dot shows the new GRAPHICS dot",
                 24'hAABBCC);

    // The 200-line interleave is OFF in packed mode (qemu pc98-vga.c:4422-4438
    // copies rows directly; MAME walks them), so gfx_odd_line must not hide the
    // graphics arm here - and in 16-colour mode the same gate is unchanged.
    gfx_odd_line = 1'b1;
    check_pixel("packed mode ignores the 200-line odd-line gate",
                24'hAABBCC);
    mix_pegc_256 = 1'b0;
    fold_bypass = 1'b0;
    check_pixel("16-colour mode keeps the odd-line gate (text over black)",
                24'h000000);
    gfx_odd_line = 1'b0;
    mix_pegc_256 = 1'b0;

    // ---------------------------------------------------------------
    // 9. 16-COLOUR EQUIVALENCE: not one dot may move (row 4's obligation).
    // ---------------------------------------------------------------
    // Every vector is checked against the bench's own closed form of the OLD
    // combinational path (fold -> power-on table -> compositor -> nibble
    // replicate), with text and dot inputs changing every dot so the new
    // registers cannot hide behind stable inputs.
    begin : equiv
      integer k;
      reg [31:0] eld;
      reg [11:0] etc;
      reg [23:0] want;
      for (k = 0; k < 24; k = k + 1) begin
        eld = 32'h1357_9BDF ^ (32'h1020_4081 * k[15:0]);
        etc = 12'h0F0 ^ {4'(k), 4'(k + 3), 4'(k + 5)};
        @(negedge clk);
        dot_x = 10'(8 * (k % 80) + (k % 8));
        line_data = eld;
        text_opaque = k[0]; text_cell = k[1]; text_colour = etc;
        comp_rule = {1'b0, k[2]};
        grph_disp = k[3];
        h_active = 1'b1; v_active = 1'b1;
        mix_pegc_256 = 1'b0; fold_bypass = 1'b0; gfx_odd_line = 1'b0;
        want = want_old_path(eld, 3'(k % 8), k[0], k[1], etc, {1'b0, k[2]},
                             k[3]);
        check_pixel("16-colour equivalence sweep", want);
      end
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_VIDEO_MIXER: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_VIDEO_MIXER: FAIL (%0d errors)", errors);
      $fatal(1, "video mixer bench failed");
    end
  end

endmodule

`default_nettype wire
