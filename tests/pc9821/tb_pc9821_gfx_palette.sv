`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GFX_PALETTE:
// The graphics palette reads the way the MACHINE's palette does, in both modes, for the DIGITAL table entirely (its eight colours, the 8-colour mode's use of only the low three index bits, and the intensity bit not changing the answer) and for the ANALOGUE table: the power-on entries are the ITF ROM's own (itf.rom 0x042F, entry 2 red / entry 4 green), a CPU write through the 0xA8-index/0xAA-G/0xAC-R/0xAE-B port reaches the displayed table at the next clock with no frame-boundary commit - the dot read in the write's own cycle is the old entry and the next dot the new one, which is what a raster palette split needs - a channel write moves only its own nibble of its own entry, the whole 4-bit index selects an entry (the intensity bit is part of it, so entry 8 differs from entry 0), and the read stays combinational so no dot of the pixel path moves. The PEGC 256-colour table is a SECOND store beside them: full bytes per channel at the full 8-bit index (NP2kai stores and renders the written byte verbatim), a registered dot-path read one clk after the index (the async form refuses every block type), and the 16-entry path unchanged by any of it.
// ---- the bench's own account of where each expectation comes from ----
// THE DIGITAL (8-COLOUR) TABLE, and why this is a specification test. The four
// palette registers 0xA8/0xAA/0xAC/0xAE are packed as one word; the machine
// powers up with 37/15/26/04; NP2kai makes those registers entries 3/1/2/0 of a
// four-entry pack, each carrying one colour in its high nibble and that colour's
// bright half in its low nibble, indexed by {G,R,B}. Working that out from the
// bytes alone gives black/blue/red/magenta in the high nibbles and
// green/cyan/yellow/white in the low ones, and the bench asserts all eight. Plus:
// 8-colour mode uses only the low three index bits.
//
// THE ANALOGUE TABLE is one entry per 4-bit index, {R,G,B} nibbles, and the
// INTENSITY PLANE SELECTS THE UPPER EIGHT. It is written on clk_sys through the CPU
// port and read combinationally by the dot path; a write reaches the next dot (a raster
// palette split - tb_pc9821_raster_palette carries the references for the line-level
// behaviour this cycle-level contract has to support).
//
// The output order is {R,G,B} in bits 11..0, which is the order the rest of the
// video path and the framework use.

module tb_pc9821_gfx_palette;
  reg  clk = 0;
  always #5 clk = ~clk;

  reg  [7:0]  idx = 0;
  reg         mode16 = 0;
  reg  [31:0] dig = 0;
  reg         we = 0;
  reg  [3:0]  widx = 0;
  reg  [1:0]  wchan = 0;     // 0 = G, 1 = R, 2 = B
  reg  [3:0]  wdata = 0;
  wire [11:0] colour;
  // The PEGC 256-colour table's ports (pegc-scope-REPORT.md 4 row 4).
  reg         p256_we = 1'b0;
  reg  [7:0]  p256_widx = 8'd0, p256_wdata = 8'd0;
  reg  [1:0]  p256_wchan = 2'd0;
  reg  [7:0]  idx256 = 8'd0;
  wire [23:0] colour256;

  // ==== DUT ====
  pc9821_gfx_palette dut (.clk(clk),
                          .idx(idx), .mode16(mode16), .dig(dig),
                          .we(we), .widx(widx), .wchan(wchan), .wdata(wdata),
                          .colour(colour),
                          .p256_we(p256_we), .p256_widx(p256_widx),
                          .p256_wchan(p256_wchan), .p256_wdata(p256_wdata),
                          .idx256(idx256), .colour256(colour256));

  // ==== CHECKS ====

  integer errors = 0;
  integer i;
  reg [7:0] n;
  reg [11:0] colour16_before;   // the 16-entry read's value before the 256 activity
  reg [3:0] gn, bn;   // the expected G and B nibbles for the entry under test
  reg [11:0] entry0 = 12'h000;

  // The eight colours the machine's power-on bytes must produce, most
  // significant nibble first: {R,G,B} with each channel all-ones or all-zero.
  function [11:0] rgb(input r, input g, input b);
    rgb = { (r ? 4'hF : 4'h0), (g ? 4'hF : 4'h0), (b ? 4'hF : 4'h0) };
  endfunction

  // The ITF ROM's power-on analogue table, {R,G,B} per entry (the source packs
  // {G,R,B}; pc9821_gfx_palette's own localparam is the same table).
  function [11:0] itf_entry(input [3:0] i);
    case (i)
      4'h0: itf_entry = 12'h000;
      4'h1: itf_entry = 12'h007;
      4'h2: itf_entry = 12'h700;
      4'h3: itf_entry = 12'h707;
      4'h4: itf_entry = 12'h070;
      4'h5: itf_entry = 12'h077;
      4'h6: itf_entry = 12'h770;
      4'h7: itf_entry = 12'h777;
      4'h8: itf_entry = 12'h444;
      4'h9: itf_entry = 12'h00F;
      4'hA: itf_entry = 12'hF00;
      4'hB: itf_entry = 12'hF0F;
      4'hC: itf_entry = 12'h0F0;
      4'hD: itf_entry = 12'h0FF;
      4'hE: itf_entry = 12'hFF0;
      default: itf_entry = 12'hFFF;
    endcase
  endfunction

  // One entry's channel write: driven at a negedge, it lands at the next posedge.
  task automatic wchan_write(input [1:0] ch, input [3:0] w, input [3:0] dat);
    begin
      @(negedge clk);
      we = 1'b1; wchan = ch; widx = w; wdata = dat;
      @(negedge clk);
      we = 1'b0;
    end
  endtask

  // Present one index and sample the registered output one dot later.
  task automatic see(input [7:0] i, input [11:0] want, input [8*72-1:0] what);
    begin
      @(negedge clk);
      idx = i;
      @(negedge clk);
      if (colour !== want) begin
        $display("FAIL %0s: index %03x read %03x, expected %03x", what, i, colour, want);
        errors = errors + 1;
      end
    end
  endtask

  reg [11:0] exp_tab [0:15];   // the analogue table as the writes so far leave it

  // ---- the write's timing: the next dot, not the next frame ----
  // A write to entry k driven at a negedge lands at the following posedge. The dot read
  // while it is presented (before that edge) is the old entry; the read after the edge is
  // the new one. Only the written channel's nibble of entry k moves; every other entry and
  // channel holds. This is the cycle-level contract the raster split rests on.
  task automatic write_timing(input [3:0] k, input [1:0] ch, input [3:0] dat,
                              input [8*64-1:0] what);
    reg [11:0] old_entry, new_entry;
    integer    j;
    begin
      old_entry = exp_tab[k];
      new_entry = old_entry;
      if (ch == 2'd0)      new_entry[7:4]  = dat;
      else if (ch == 2'd1) new_entry[11:8] = dat;
      else                 new_entry[3:0]  = dat;
      mode16 = 1'b1;
      @(negedge clk);
      idx = {4'h0, k};
      we = 1'b1; wchan = ch; widx = k; wdata = dat;
      #1;
      if (colour !== old_entry) begin
        $display("FAIL %0s: entry %0d read %03x in the write's own cycle, expected the old %03x",
                 what, k, colour, old_entry);
        errors = errors + 1;
      end
      @(negedge clk);
      we = 1'b0;
      if (colour !== new_entry) begin
        $display("FAIL %0s: entry %0d read %03x one clk after the write, expected %03x",
                 what, k, colour, new_entry);
        errors = errors + 1;
      end
      exp_tab[k] = new_entry;
      for (j = 0; j < 16; j = j + 1) begin
        if (dut.disp[j] !== exp_tab[j]) begin
          $display("FAIL %0s: entry %0d = %03x after the write to entry %0d, expected %03x",
                   what, j, dut.disp[j], k, exp_tab[j]);
          errors = errors + 1;
        end
      end
    end
  endtask

  initial begin
    repeat (4) @(negedge clk);

    // ---- the power-on analogue table, before any write ----
    // The table initialises to the ITF table, so the very first frame already shows it.
    mode16 = 1'b1;
    for (i = 0; i < 16; i = i + 1) begin
      idx = i[7:0];
      @(negedge clk);
      if (colour !== itf_entry(i[3:0])) begin
        $display("FAIL power-on analogue entry %0d = %03x, expected %03x",
                 i, colour, itf_entry(i[3:0]));
        errors = errors + 1;
      end
    end

    // ---- the machine's power-on digital bytes ----
    dig = { 8'h37, 8'h15, 8'h26, 8'h04 };
    mode16 = 1'b0;

    see(8'd0, rgb(0,0,0), "digital entry 0 (0xAE high nibble)");
    see(8'd1, rgb(0,0,1), "digital entry 1 (0xAA high nibble)");
    see(8'd2, rgb(1,0,0), "digital entry 2 (0xAC high nibble)");
    see(8'd3, rgb(1,0,1), "digital entry 3 (0xA8 high nibble)");
    see(8'd4, rgb(0,1,0), "digital entry 4 (0xAE low nibble)");
    see(8'd5, rgb(0,1,1), "digital entry 5 (0xAA low nibble)");
    see(8'd6, rgb(1,1,0), "digital entry 6 (0xAC low nibble)");
    see(8'd7, rgb(1,1,1), "digital entry 7 (0xA8 low nibble)");

    // The digital read must use only the low three index bits: the intensity bit
    // is not a colour in 8-colour mode, so idx[3] must not change the answer.
    see(8'd5,  rgb(0,1,1), "digital entry 5");
    see(8'd13, rgb(0,1,1), "digital 8-colour ignores idx[3]");

    // ---- the analogue table through its write port ----
    // Put a distinguishable nibble in every entry: entry n -> R=n, G=15-n, B=n^5.
    for (i = 0; i < 16; i = i + 1) begin
      n = i;
      gn = 4'd15 - n[3:0];
      bn = n[3:0] ^ 4'd5;
      wchan_write(2'd1, i[3:0], n[3:0]);    // R
      wchan_write(2'd0, i[3:0], gn);        // G
      wchan_write(2'd2, i[3:0], bn);        // B
    end
    // The written entries, with no frame boundary in between.
    mode16 = 1'b1;
    for (i = 0; i < 16; i = i + 1) begin
      n = i;
      gn = 4'd15 - n[3:0];
      bn = n[3:0] ^ 4'd5;
      see(n, { n[3:0], gn, bn }, "analogue entry after its write");
    end
    // The intensity bit must select the upper half, so entry 0x8 must differ from
    // entry 0x0. Both are checked against the pattern above, and the pair is what
    // proves idx[3] is part of the entry select rather than ignored.
    idx = 8'h00;
    @(negedge clk);
    entry0 = colour;
    idx = 8'h08;
    @(negedge clk);
    if (colour === entry0) begin
      $display("FAIL analogue entries 0 and 8 are the same colour: idx[3] is being ignored, and the intensity plane would paint nothing");
      errors = errors + 1;
    end

    // ---- the write's own timing, per channel ----
    for (i = 0; i < 16; i = i + 1) begin
      n = i;
      gn = 4'd15 - n[3:0];
      bn = n[3:0] ^ 4'd5;
      exp_tab[i] = { n[3:0], gn, bn };
    end
    write_timing(4'd10, 2'd1, 4'h9, "an R write (0xAC)");
    write_timing(4'd3,  2'd0, 4'h2, "a G write (0xAA)");
    write_timing(4'd12, 2'd2, 4'hE, "a B write (0xAE)");

    // ---------------------------------------------------------------
    // THE PEGC 256-COLOUR TABLE (row 4): a SECOND store beside disp, not a
    // widening of them. Full bytes per channel (NP2kai stores the written byte
    // verbatim and pal_make9821 renders it verbatim), the FULL 8-bit index, and
    // a REGISTERED dot read (the async form refuses every block type - the
    // 276007 family this module's header records). FAIL-FIRST: before this
    // table existed the 256-colour arm had no store at all.
    colour16_before = colour;
    p256_we = 1'b1; p256_widx = 8'h2B; p256_wchan = 2'd1; p256_wdata = 8'hFE;  // R
    @(negedge clk);
    p256_wchan = 2'd0; p256_wdata = 8'h01;                                     // G
    @(negedge clk);
    p256_wchan = 2'd2; p256_wdata = 8'h80;                                     // B
    @(negedge clk);
    p256_we = 1'b0;
    idx256 = 8'h2B;
    @(negedge clk);
    if (colour256 !== 24'hFE0180) begin
      $display("FAIL: 256-entry 2B read %06x, want fe0180 (full bytes, NP2kai)", colour256);
      errors = errors + 1;
    end
    // The FULL 8-bit index: 0x2B and 0x0B are different entries.
    idx256 = 8'h0B;
    @(negedge clk);
    if (colour256 !== 24'h000000) begin
      $display("FAIL: 256-entry 0B read %06x, want 000000 (the index is 8 bits)", colour256);
      errors = errors + 1;
    end
    // The read is REGISTERED: the value appears one clk after the index.
    idx256 = 8'h2B;
    #1;
    if (colour256 !== 24'h000000) begin
      $display("FAIL: the 256-colour read must not be combinational (got %06x early)",
               colour256);
      errors = errors + 1;
    end
    @(negedge clk);
    if (colour256 !== 24'hFE0180) begin
      $display("FAIL: the registered read did not settle one clk after the index");
      errors = errors + 1;
    end
    // ... and the 16-entry path is untouched by any of it: the combinational
    // read answers the same value before and after the 256-colour activity.
    if (colour !== colour16_before) begin
      $display("FAIL: the 256-colour table moved the 16-colour read (%03x -> %03x)",
               colour16_before, colour);
      errors = errors + 1;
    end

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GFX_PALETTE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_GFX_PALETTE: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_GFX_PALETTE: TIMEOUT");
  end

endmodule
