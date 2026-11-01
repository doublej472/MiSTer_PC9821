// PC-9821 character generator (CG): the glyph fetch, the JIS row cache, the window and
// the configuration record.
//
// Kept apart from pc9821_gdc_text so the SDRAM glyph burst can be measured apart from the
// raster. It owns:
//   - the CG code/line registers and the 0xA1/0xA3/0xA5/0xA9 port decode;
//   - the writable user-CG (gaiji) store and the 0xA4000 window's byte decode;
//   - the 4 KiB ANK table (its only M10K glyph store) and the pack's FONT.ROM glyph
//     fetch on the SDRAM's second port (font_req_*), plus the scanout's row cache;
//   - the software-DIP configuration record (14 cells, model-selected with a computed
//     sum-check byte) and the CPU/size cells: the STATIC READ-ONLY configuration view
//     the ITF reads, which no guest write can alter.
// The raster, the text fetch and the pixel outputs stay in pc9821_crtc; the scanout
// asks this module for its byte by address and gets it, and this module reads the
// text RAM only through the port pc9821_crtc presents for the row-cache walker.
//
// One clock: clk_sys gated by pixel_ce.
`default_nettype none

module pc9821_cg (
    input wire clk_sys,
    input wire rst_n_sys,
    input wire pixel_ce,

    // The device bus.
    input  wire       io_wr,
    input  wire       io_rd,
    input  wire [7:0] io_addr,
    input  wire [7:0] io_din,
    output wire [7:0] io_dout,

    // Memory-mapped CG window (0xA4000-0xA4FFF) port. The window responder lives in the
    // memory subsystem; glyph selection and every store live here, so the window and port
    // 0xA9 cannot disagree about a byte. The window presents the byte position inside its
    // 32-byte repeating view ({page, row}) it answers; a store needs writable user-CG.
    input  wire  [4:0] cg_win_byte_sel,
    input  wire        cg_win_rd,
    output wire  [7:0] cg_win_dout,
    input  wire  [7:0] cg_win_din,
    input  wire        cg_win_we,
    // Set while the selected code's JIS glyph burst is in flight: pc9821_window_responder holds
    // its capture, so the window answers the CURRENT code's byte.
    output wire        cg_win_byte_hold,

    // Character-generator glyph fetch. The JIS glyph classes read the machine's
    // FONT.ROM copy at pack_base + FONT_PACK_OFFSET; pc9821_memory_subsystem owns
    // both the offset and the port. The whole 32-byte glyph block is ONE request (the
    // address is its 8-dword-aligned base); the port answers eight font_word_valid
    // beats, word 0 first. The base is 32-byte aligned, so the 8-dword burst cannot
    // cross an SDRAM row boundary.
    output wire  [18:0] font_req_addr,
    output wire         font_req,
    input  wire         font_word_valid,
    input  wire  [31:0] font_word_data,
    // Set while port 0xA9's JIS read must wait for the code's own SDRAM burst:
    // pc9821_iobus holds S_DEVWAIT, so the read never answers the previous glyph
    // Every other class answers immediately.
    output wire         cg_rd_hold,

    // Font loader port (rom_loader; the pack's FONT.ROM copy). 18 bits covers ANK + the
    // whole FONT.ROM; the ANK store is ANK_AW wide and this is sliced into it below.
    /* verilator lint_off UNUSEDSIGNAL */  // only the ANK (words 0..2047) reaches M10K
    input wire [17:0] font_ld_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input wire [15:0] font_ld_data,
    input wire        font_ld_we,

    // The record restore: the MACHINE-RESET seed's one-cycle pulse (pc9821_iobus's
    // `sdip_seed_pulse`), which restarts the 38-byte walk at store 0x810. It may be asserted
    // while `rst_n_sys` is low (the seed is), which is why the walk below is not clamped by
    // it. The reset seed is this walk's only source and the walk has no zero mode.
    input  wire        cg_record_restore,

    // The OSD Machine field's LIST POSITION (z486_mister P1O[31:28], 0 = Xe10): the
    // software-DIP record is MODEL DATA and the two ITFs carry their own tables - see
    // cg_record_byte below. Sampled into bios_set_eff at the machine-reset strobe only.
    input  wire  [3:0] bios_set,

    // The OSD's selected guest RAM in MIB (1/2/4/8/16/32/64/96), and the enable for the
    // configuration-image view below. A bench that drives neither keeps the power-up
    // store, which is what every bench outside tb_pc9821_cg_read_path does on purpose.
    // cfg_ram_mib is SAMPLED AT MACHINE RESET ONLY (cfg_ram_mib_eff below).
    input  wire  [6:0] cfg_ram_mib,
    input  wire        cfg_seed_en,
    // The ITF's own CPU-mode reset (`out 0xF0`, pc9821_iobus's cpu_reset_req). One pulse per
    // POST pass clears the write-through latch below, so the configuration read echo returns to
    // the static OSD view for the record check and drive probe that run AFTER the KANJI
    // CG-RAM test has echoed its own writes.
    input  wire        cfg_seed_reload,

    // ---- The scanout's view, presented by pc9821_crtc ----
    // The ANK scanout word address (the ANK store's port B).
    input  wire [10:0] ank_rd_addr,
    // The row cache's read coordinates and bank, decoded from the scanout's fetch state.
    input  wire [1:0]  jc_rd_bank,
    input  wire [6:0]  jc_rd_cell,
    input  wire [1:0]  jc_rd_word,
    // The user-CG (gaiji) store's scanout read address.
    input  wire [12:0] cg_ram_vid_addr,
    // The text RAM read the row-cache walker borrows (pc9821_crtc owns the TRAM).
    input  wire [7:0]  tram_vid_q,
    // Raster and configuration the walker needs (the walk is raster-locked).
    input  wire [7:0]  v_pitch,
    input  wire        v_col40,
    // The start word of the partition the requested row is in.
    input  wire [15:0] v_sad,
    // The walk request, from pc9821_crtc's text line sequencer: wk_go on the first line of a
    // character row (or the row-0 re-walk slot), the requested row's index in its partition
    // (wk_k) and the cache bank to fill (wk_bank). Rows are whatever the GDC's LR, the CRTC
    // registers and the display partitions make them, not a fixed 16-line grid.
    input  wire        wk_go,
    input  wire [9:0]  wk_k,
    input  wire [1:0]  wk_bank_in,
    input  wire [9:0]  hdot,

    // The bytes the scanout's render reads.
    output wire [15:0] ank_word,
    output wire [31:0] jc_rd_q,
    output wire [7:0]  cg_ram_vid_q,
    // The walker's text-RAM read port.
    output wire        wk_tr_read,
    output wire [13:0] wk_tr_addr,
    // A saturating count of walk slots whose walk was skipped because the previous walk was
    // still in flight.
    output wire [15:0] dbg_wk_skips
);

  // ---------------------------------------------------------------
  // CG (character generator) registers: 0xA1/0xA3 code, 0xA5 line
  // ---------------------------------------------------------------
  // Software reads glyph bitmaps out of here to draw text into graphics VRAM, which is
  // how the games put kanji on screen. Register semantics follow NP2kai cgrom.c.
  // Power-up = reset values: the code/lr/line registers feed cg_rd_addr, and a
  // pre-first-edge X there would make the seed compare (and with it cfg_seed_hit_q's
  // first load) X even with the mux flops seeded.
  /* verilator lint_off PROCASSINIT */   // the initialisers are the registers' power-up values
  reg [15:0] cg_code = 16'h0000;
  reg  [4:0] cg_line = 5'd0;
  reg        cg_lr = 1'b0;   // 0xA5 bit 5 inverted: kanji right-half select
  /* verilator lint_on PROCASSINIT */

  // Character generator: one class table, three stores. 0xA1 is the code HIGH byte and
  // 0xA3 the LOW; the code is not a JIS word, because ZUN writes `codepoint & 0xFF` to
  // 0xA1 and `(codepoint >> 8) - 0x20` to 0xA3 (rec98/th01/hardware/grppsafx.cpp:46-47)
  // -- so 0xA1 is the JIS COLUMN and 0xA3 the row minus 0x20 (NP2kai cgrom.c oa1/oa3).
  // The classes, exactly as NP2kai's TWO decoders decide them - port 0xA9 (cgrom_ia9,
  // io/cgrom.c:193-226) and the window (cgwindowset, :11-53) do NOT share their ver0.78
  // test or their branch order:
  //   gaiji    code[15:8] != 0 and code[6:0] in {0x56,0x57}: the writable user-CG store,
  //            NOT the font -- the machine has separate battery-backed RAM there.
  //   ver0.78  code[6:0] in {0x09,0x0A,0x0B}: the JIS block with NO half offset, and 0
  //            when the half bit is set. EVERY character the five games draw is here.
  //   two-byte code[15:8] != 0 otherwise: the JIS block, half by 0xA5 bit 5.
  //   ANK      one-byte (port: and not ver0.78): the 8x16 ANK table, 0xA5 bit 4 clear.
  wire        cg_two_byte = |cg_code[15:8];
  wire [6:0]  cg_hi7      = cg_code[14:8];
  wire [6:0]  cg_lo7      = cg_code[6:0];
  wire        cg_gaiji    = cg_two_byte && ((cg_lo7 == 7'h56) || (cg_lo7 == 7'h57));
  // TWO ver0.78 tests, split exactly where NP2kai splits them: the port's
  // is the UNMASKED low byte (cgrom.c:197 `type = cr->code & 0x00ff`), the window's the
  // masked low7 inside its two-byte branch (cgrom.c:27 `code = cr->code & 0x007f`) - and
  // the window's one-byte branch (cgrom.c:21-25) is the ANK page for EVERY low byte,
  // so 0x89-0x8B are ver0.78 on neither side and 0x09-0x0B only on the port's.
  wire        cg_v078_p   = (cg_code[7:0] >= 8'h09) && (cg_code[7:0] < 8'h0C);
  wire        cg_ver078   = (cg_lo7 >= 7'h09) && (cg_lo7 < 7'h0c);   // the window's test
  // Port 0xA9's blank arms: one-byte 0x09-0x0B names fontrom[0x90 + row],
  // which font_load's ZeroMemory passes and no loader writes (font/font.c:145-151), so
  // NP2kai returns 0 there; two-byte ver0.78 with the half bit set falls out of the
  // branch with no return (cgrom.c:198-207) and returns 0 too. Neither takes a font
  // burst: the answer is the constant 0, so the read must not wait for one.
  wire        cg_p_blank  = cg_v078_p && (cg_lr || !cg_two_byte);
  wire        cg_p_ank    = !cg_two_byte && !cg_v078_p;
  // The fetched block serves every TWO-BYTE non-gaiji read and the window's two-byte
  // non-gaiji pages. A one-byte code never fetches: NP2kai answers one-byte 0x09-0x0B
  // from its zeroed slot and every other one-byte code from the ANK table/page.
  wire        cg_jis      = cg_two_byte && !cg_gaiji;   // reads the FONT.ROM copy
  // The 0x0C-0x0F and 0x58-0x5F rows are the classes the CG window folds into two
  // pages: its low page takes the left half and its high page the right (cgwindowset).
  wire        cg_wide     = ((cg_lo7 >= 7'h0c) && (cg_lo7 < 7'h10)) ||
                            ((cg_lo7 >= 7'h58) && (cg_lo7 < 7'h60));

  // The JIS glyph address in FONT.ROM, verified by rendering four glyphs from
  // bios/xe10/FONT.ROM (sec. 4)
  //   32 bytes at 0x1800 + (ku - 0x21)*0xC00 + (ten - 0x20)*0x20
  // ku = the JIS row = code[6:0] + 0x20, ten = the column = code[14:8]; the first 16
  // bytes are the left half and the last 16 the right half. NOT NP2kai's `(code & 0x7f7f)
  // << 4`, which indexes a private 528 KiB array whose strides are transposed against the
  // dump's and whose index space (0x84000) exceeds it (0x46800): it reads the wrong glyph
  // off a verbatim FONT.ROM copy.
  function automatic [18:0] cg_jis_addr(input [6:0] hi7, input [6:0] lo7);
    reg [7:0] ku_i, ten_i;
    begin
      ku_i  = {1'b0, lo7} - 8'h01;      // ku - 0x21
      ten_i = {1'b0, hi7} - 8'h20;      // ten - 0x20
      cg_jis_addr = 19'h1800 + {ku_i, 11'b0} + {1'b0, ku_i, 10'b0}
                              + {6'd0, ten_i, 5'b0};
    end
  endfunction

  wire [18:0] cg_jis_base = cg_jis_addr(cg_hi7, cg_lo7);

  // ---------------------------------------------------------------
  // The fetched glyph block
  // ---------------------------------------------------------------
  // The JIS classes read the pack's FONT.ROM copy at pack_base + FONT_PACK_OFFSET. A
  // 32-byte block holds one glyph, both halves, and it refetches when the code's block
  // address changes - once per character. It is a BLOCK RAM (8 x 32 words, one whole word
  // per burst beat), not a 256-bit shadow of the font (a 65k-register shadow is what
  // stopped this design fitting before) and not 256 flip-flops either: as flops it cost
  // 256 registers PLUS two 32:1 x 8-bit read muxes, and `res_exp_map` prices the RAM form
  // at 17 ALMs against 218 for the flop form (tools/res_exp_map.py).
  // ONE request fetches the whole block: font_req is held for the eight
  // font_word_valid beats and the address is the block BASE, so the beats arrive as one
  // 8-dword SDRAM burst in word order, beat k into word k.

  // THE PORT IS SHARED WITH THE SCANOUT'S ROW-CACHE WALKER: the same fmem burst both fills this
  // block (the CPU's 0xA9/0xA4000 read) and the scanout's per-cell row cache. The CPU wins a
  // grant - its read is the latency-critical one, the walker has a whole text row of slack - and
  // the owner and address are LATCHED at the grant, so a request that loses arbitration can
  // never switch fmem_addr mid-burst.
  // A block RAM read is CLOCKED, one cycle behind the address, so the read register's data
  // is the word the address named in the PREVIOUS cycle. Both readers hold their address for
  // the whole access (port 0xA9's index is the CG code/line registers and changes only on an
  // OUT; the window holds byte_sel across S_READ_ISSUE/S_READ_WAIT/S_READ_CAPTURE, so its
  // capture is two cycles after the position moves), which is what makes the registered read
  // invisible to the WINDOW. Port 0xA9 is the reader that can sample in the register's lagging
  // cycle, because it is the one that can arrive exactly as the burst's last beat lands, so it
  // is held one cycle longer than the burst (see THE PORT'S OPEN CYCLE below). A byte-granular
  // write into a word does NOT infer, in any block type
  // (measured for the same shape on the palette mirror): the beat writes a WHOLE 32-bit word.
  localparam integer BLK_WORDS = 8;
  (* ramstyle = "M10K" *) reg [31:0] cg_blkm [0:BLK_WORDS-1];
  integer blk_i;
  initial begin   // the reset value the flop form's `cg_block <= 256'd0` installed
    for (blk_i = 0; blk_i < BLK_WORDS; blk_i = blk_i + 1) cg_blkm[blk_i] = 32'h0000_0000;
  end
  reg  [18:0]  fnt_base_r;
  reg          fnt_act;       // the CPU block's burst is in flight
  reg  [3:0]   fnt_step;      // word 0..7 of the 32-byte block

  // ---- The scanout's JIS row cache and its walker ----
  // The font is out of M10K. The scanout draws from a 3-bank x 80-cell x 4-dword
  // row cache, and a walker fills the bank for the NEXT text row from SDRAM while the scanout
  // reads the bank for the row on screen. Each bank entry holds one cell's 16-byte half-glyph,
  // so the scanout's read is the same one-cycle registered read u_font port B had.
  // The bank is not a function of the row number: pc9821_crtc's text line sequencer counts the
  // GDC's row reloads mod 3 (its ord_inc) and carries the count across the frame boundary, so a
  // row draws from the bank its fill was made in, and the walker is sent to the bank after the
  // one on screen (wk_bank_in). A row-number parity cannot do this: a frame's row count is
  // whatever the LR, the CRTC registers and the partitions make it (25 rows at 400 lines is an
  // odd ring, so row[0] would alias the last row onto row 0's bank).
  // The banks are PACKED (bank*320 + cell*4 + word = 960 dwords = 3 M10K, vs 7 M10K for an
  // 11-bit {bank[1:0], cell, word} address).
  localparam integer JC_CELLS = 80;
  localparam integer JC_WORDS = 4;                        // 4 dwords = 16 bytes per cell
  localparam integer JC_BANK  = JC_CELLS * JC_WORDS;      // 320 dwords per bank
  localparam integer JC_DEPTH = 3 * JC_BANK;              // 960 dwords (3 banks)
  localparam integer JC_AW    = $clog2(JC_DEPTH);         // 10
  // The walker's FSM states.
  localparam [2:0] W_IDLE=3'd0, W_LO=3'd1, W_LOC=3'd2, W_HI=3'd3, W_HIC=3'd4,
                   W_DEC=3'd5, W_REQ=3'd6;
  reg          wk_act;        // the walker's cache-fill burst is in flight
  reg  [2:0]   wk_beat;       // dword 0..7 of the in-flight 8-dword burst
  reg          wk_req;        // the walker asks for a grant (held until served)
  reg  [6:0]   wk_cell;       // the TRAM cell being walked
  reg  [9:0]   wk_row;        // the text row being walked: its index in its partition
  // The start word of the walked row's partition, latched with the row: the walk spans about
  // 1.5 lines, and pc9821_crtc's v_sad follows its next-row partition (and the row-0 re-walk
  // slot) line by line, so a live read would take a later partition's start mid-row.
  reg  [15:0]  wk_sad;
  reg  [2:0]   wk_state;      // walker FSM
  reg          wk_wr_en;      // write the row cache this edge
  reg  [JC_AW-1:0] wk_wr_addr;
  reg  [31:0]  wk_wr_data;
  reg  [18:0]  wk_glyph_r;   // the current cell's JIS glyph base, latched at decode
  reg          wk_half_r;    // the current cell's JIS half, latched at decode
  reg  [7:0]   wk_code_lo, wk_code_hi;
  reg          wk_jis2nd;    // the previous cell was a JIS left half
  reg  [7:0]   wk_pair_row, wk_pair_ten;
  reg  [15:0]  wk_skip_cnt;  // saturating count of walk slots skipped because a walk was in flight
  // The walker's bank for the row it fills, latched with the row: pc9821_crtc numbers rows'
  // banks by a mod-3 count of the GDC's row reloads, and asks for the bank after the one being
  // drawn, so the walker never fills the bank the scanout is reading (assertion below).
  reg  [1:0]   wk_bank;
  // The packed write address of the dword about to be stored (the same form as the read).
  /* verilator lint_off WIDTHEXPAND */  // the packed address is value-bounded (bank<=2, cell<=79, word<=3 -> <= 959 < 1024),
  /* verilator lint_off WIDTHTRUNC */    // so the 32-bit product widths and the truncation to JC_AW are both intentional
  wire [JC_AW-1:0] wk_wr_off = wk_bank * JC_BANK + {wk_cell, 2'b00} + wk_beat[1:0];
  /* verilator lint_on WIDTHEXPAND */
  /* verilator lint_on WIDTHTRUNC */

  // The shared glyph port: the CPU block wins, the walker yields. The owner and address
  // are LATCHED at the grant, so a losing request never switches fmem_addr mid-burst.
  // THE WALKER'S ADDRESS IS ITS OWN LATCHES, NOT A COPY TAKEN AT THE GRANT: `wk_glyph_r` and
  // `wk_half_r` are written ONLY in W_DEC, and the walker leaves W_DEC by going to W_REQ and stays
  // there for the whole `wk_act` burst (the burst's last beat is what returns it to W_LO/W_IDLE) -
  // so the two are already frozen for the burst's life and the `wk_addr`/`wk_half` snapshots of
  // them were dead copies. `wk_half_r` is read the same way for the beat-half keep test below.
  wire fnt_start = !fnt_act && (cg_jis_base != fnt_base_r) && cg_jis;
  wire cpu_want  = fnt_start && !wk_act;
  wire start_cpu = cpu_want;
  wire start_wk  = wk_req && !wk_act && !fnt_act && !cpu_want;
  assign font_req      = fnt_act | wk_act | start_cpu | start_wk;
  assign font_req_addr = fnt_act ? fnt_base_r
                       : start_cpu ? cg_jis_base : wk_glyph_r;

  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      // The block RAM keeps its power-up zeroes across a reset; a JIS read cannot consume
      // them because fnt_base_r resets to "no valid block", so cg_blk_here stays false and
      // both read ports hold the bus until the code's burst has landed.
      fnt_base_r <= 19'h7FFFF;   // no valid block base, so the first fetch fires
      fnt_act    <= 1'b0;
      fnt_step   <= 4'd0;
    end else begin
      if (fnt_start && !wk_act) begin
        fnt_act    <= 1'b1;
        fnt_step   <= 4'd0;
        fnt_base_r <= cg_jis_base;
      end
      if (fnt_act && font_word_valid) begin
        // fnt_step is 0..7 (it wraps at 7 a few lines below), so [2:0] names the word.
        cg_blkm[fnt_step[2:0]] <= font_word_data;
        if (fnt_step == 4'd7) fnt_act  <= 1'b0;
        else                  fnt_step <= fnt_step + 4'd1;
      end
    end
  end

  // ---- the writable user-CG (gaiji) store ----
  // ((code & 0x7F7F) << 4) + lr + row over the writable codes is 128 pages of 64 bytes
  // = 8 KiB, and {code[14:8], code[0], lr, row} is that address: dropping the page field
  // aliases all 128 pages onto the same cells and corrupts the firmware's 31-page
  // memory-switch table. The 0xA9 write gate is the narrow UNMASKED 0x007E test (the
  // READ masks to 0x7F, so 0x58xx reads the store and cannot write it). The WINDOW's
  // gate additionally requires the TWO-byte class, because NP2kai's cgwindowset sets
  // cgwindow.writable only inside its `code & 0xff00` branch (io/cgrom.c:29-31): a
  // one-byte 0x0056/0x0057 window store is dropped there, and must be here.
  wire [12:0] cg_ram_addr = {cg_code[14:8], cg_code[0], cg_lr, cg_line[3:0]};
  wire        cg_ram_we   = io_wr && (io_addr == 8'hA9) &&
                            ((cg_code & 16'h007E) == 16'h0056);
  wire        cg_gaiji_writable = cg_two_byte && ((cg_code & 16'h007E) == 16'h0056);

  // The window's byte position inside its 32-byte repeating view ({page, row}),
  // and the store address it selects when the class is user CG.
  wire        win_page = cg_win_byte_sel[4];
  wire [3:0]  win_row  = cg_win_byte_sel[3:0];
  wire [12:0] cg_win_ram_addr = {cg_code[14:8], cg_code[0], cg_lr, win_row};

  // The two CPU-side views are separate bus transactions (a port I/O and a memory access
  // cannot be in flight together), so they share a port with a muxed address and write;
  // the scanout takes the other. TWO PORTS IS WHAT A BLOCK RAM HAS - a third made Quartus
  // serve the scanout read from a 65k-register shadow, which stopped the design fitting.
  // pc9821_dpram is what infers as M10K here. Both CPU views take the port's registered
  // read: the window holds its byte select for the whole access (it advances only in
  // S_READ_CAPTURE) so one held read address covers issue, wait and capture, and win_rd_d
  // keeps the mux on the window for the wait cycle; the 0xA9 view is addressed
  // combinationally from the CG registers.
  // The power-up seed: unseeded, win_rd_d's X makes
  // cg_rd_win = cg_win_rd | X = X before the first window access and the shared
  // cg_ram/ANK port-A address is X for a cycle - a config-seed read landing
  // there returns X instead of the seeded byte.
  /* verilator lint_off PROCASSINIT */   // the initialisers are the registers' power-up values
  reg         win_rd_d = 1'b0;
  /* verilator lint_on PROCASSINIT */
  always @(posedge clk_sys) win_rd_d <= cg_win_rd;
  wire        cg_rd_win  = cg_win_rd | win_rd_d;
  wire [12:0] cg_rd_addr = cg_rd_win ? cg_win_ram_addr : cg_ram_addr;
  wire        cg_wr_win  = !cg_ram_we && cg_win_we && cg_gaiji_writable &&
                           win_page;
  wire [12:0] cg_wr_addr = cg_wr_win ? cg_win_ram_addr : cg_ram_addr;
  wire  [7:0] cg_wr_data = cg_wr_win ? cg_win_din : io_din;
  wire        cg_we      = cg_ram_we || cg_wr_win;
  // One address for both: a read and a write never coincide (one bus access at a time),
  // and when there is a write this cycle it is the write address that matters. The OSD
  // record restore below folds a second writer (cg_rec_step) onto the same port, gated to
  // cycles when neither guest view is using it.
  wire  [7:0] cg_ram_read;

  wire  [7:0] cg_ram_q;   // cg_ram_read, unless the configuration image answers for it (below)

  // The 4 KiB 8x16 ANK table, loaded from the pack. 256 codes x 16 rows = a
  // 12-bit byte address, and the byte select is its low bit. Both CPU-side views
  // address it: port 0xA9 with the register row, the window with its own row.
  wire [15:0] font_cg_word;
  wire [11:0] cg_ank_port_addr = {cg_code[7:0], cg_line[3:0]};
  wire [11:0] cg_ank_win_addr  = {cg_code[7:0], win_row};
  wire  [7:0] cg_ank_port_byte = cg_ank_port_addr[0] ? font_cg_word[15:8]
                                                     : font_cg_word[7:0];
  wire  [7:0] cg_ank_win_byte  = cg_ank_win_addr[0]  ? font_cg_word[15:8]
                                                     : font_cg_word[7:0];

  // The software-DIP configuration record the restore walk writes at store 0x810..0x81D:
  // the same 14 bytes the static view below answers with, so the scanout's copy and the
  // guest's read can never drift apart. Byte i is store 0x810+i; provenance is on the INIT
  // parameter below.
  localparam [12:0]  CG_RECORD_ADDR  = 13'h810;

  // THE RECORD IS MODEL DATA AND ITS SUM-CHECK BYTE IS COMPUTED, NOT STORED. The ITF
  // validates it with two checks (BANK4@0xFC677-0xFC6B5): rows 8/9 must be the AA55 marker,
  // and the ten bytes at rows 1..0xA must sum to 0 mod 256. Each model's ITF carries its own
  // factory table - Xe10: BANK4@0x4924 `c1 8c 81 cd ff 00 00 aa 55 67`, Xe:
  // bios/xe/BANK4.BIN@0x48E8 `c1 8c 80 cd ff 00 00 aa 55 68` - and the two differ only in
  // row 3 and the compensating row A: ROW A IS THE CHECKSUM, -(sum of rows 1..9) mod 256,
  // which both dumps satisfy (0x67 / 0x68) and which is computed here so any record byte an
  // OSD setting ever owns keeps the ITF's check valid. Rows 0xB/0xC are the ITF code's own
  // stores (Xe10 BANK4@0x489C/0x48A2 = 0x86/0x8A, Xe writes 0x82 at row 0xC), row 0xD is
  // BANK4@0xFD49F's 0xFF, and row 0 (0x04) is the Xa7C9W runtime capture's (qemu-pc98
  // roms/pc98bios/memsw.inc row code 0x20 line 0x00) - no ITF site reads it (an open question).
  function automatic [7:0] cg_record_row(input [3:0] idx, input model_xe);
    begin
      case (idx)
        4'd0:  cg_record_row = 8'h04;
        4'd1:  cg_record_row = 8'hC1;
        4'd2:  cg_record_row = 8'h8C;
        4'd3:  cg_record_row = model_xe ? 8'h80 : 8'h81;
        4'd4:  cg_record_row = 8'hCD;
        4'd5:  cg_record_row = 8'hFF;
        4'd6:  cg_record_row = 8'h00;
        4'd7:  cg_record_row = 8'h00;
        4'd8:  cg_record_row = 8'hAA;   // the ITF's marker high byte
        4'd9:  cg_record_row = 8'h55;   // the ITF's marker low byte
        4'd11: cg_record_row = 8'h86;
        4'd12: cg_record_row = model_xe ? 8'h82 : 8'h8A;
        4'd13: cg_record_row = 8'hFF;
        default: cg_record_row = 8'h00; // row 10 is the computed checksum, never this
      endcase
    end
  endfunction

  // Row A (store 0x81A): the value that completes the ITF's ten-byte sum to 0 mod 256.
  // The sum reduces to a per-model constant. Rows 1..9 are all fixed except row 3
  // (`model_xe ? 8'h80 : 8'h81`); the fixed rows {C1,8C,CD,FF,00,00,AA,55} sum to
  // 0x18 mod 256, so rows 1..9 sum to 0x99 when model_xe = 0 (row 3 = 0x81, the Xe10
  // table's own 0x67 completing byte) and to 0x98 when model_xe = 1 (row 3 = 0x80, the
  // Xe table's 0x68). The two-arm generic loop computed this every clk_sys through
  // `cfg_seed_byte`; the direct select is value-identical for every model_xe, and any
  // change to the row table above must re-derive these two constants.
  function automatic [7:0] cg_record_cksum(input model_xe);
    cg_record_cksum = model_xe ? 8'h68 : 8'h67;
  endfunction

  function automatic [7:0] cg_record_byte(input [3:0] idx, input model_xe);
    cg_record_byte = (idx == 4'd10) ? cg_record_cksum(model_xe)
                                    : cg_record_row(idx, model_xe);
  endfunction

  // The dpram's power-up literal: cg_record_byte(idx, 1'b0) for idx 0..13 (the Xe10 model,
  // which is also the config-less default), spelled out because a function call in a
  // parameter override is the class Quartus 17.0.2 refuses (see pc9821_iobus's bit-select
  // note). The reset walk rewrites the RAM with the SELECTED model's rows before the CPU can
  // read, and tb_pc9821_cg_read_path pins the power-up store against cg_record_byte so this
  // literal and the table cannot drift apart.
  localparam [111:0] CG_RECORD_INIT = 112'hff8a_8667_55aa_0000_ffcd_818c_c104;

  // THE OSD SETTINGS ARE SAMPLED AT MACHINE RESET ONLY (the msw-cell pattern pc9821_crtc's
  // cfg_fdd_mode latch follows). The
  // static view below is defined from these latches, never from the live
  // pins, so a mid-run OSD change cannot move a configuration cell under the running
  // firmware - the new value is picked up at the next machine reset / reload.
  /* verilator lint_off PROCASSINIT */   // the initialisers are the registers' power-up values
  reg [3:0] bios_set_eff   = 4'd0;   // power-up default: set 0, the Xe10 record
  reg [6:0] cfg_ram_mib_eff = 7'd16;
  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      bios_set_eff    <= bios_set;
      cfg_ram_mib_eff <= cfg_ram_mib;
    end
  end
  /* verilator lint_on PROCASSINIT */
  wire model_xe = (bios_set_eff == 4'd1);

  // The DIP PORT MIRROR at store 0x40..0x5B - the second battery-backed run in this
  // array, and the thing BANK4@0xFC42D copies INTO the software-DIP ports during POST
  // (bank A from store 0x50..0x5B, bank B from 0x40..0x4B, the CG window at code 0x0156).
  // Those 24 bytes are the DIP image itself, and the firmware keeps them so: SETUP's
  // per-index accessors write each byte to the port AND to this cell through 0xA9 in the
  // same routine (the table at BANK3@0x21ED-0x2321, its addressing helper at BANK3@0x2322:
  // A1 = dl + (cl>>4), A3 = dh & 0x7F, A5 = ((dh & 0x80)>>2) + (cl & 0xF), so a bank-A
  // entry with dx=0x5601 lands at store 0x50+index and a bank-B entry with dx=0xD601 at
  // 0x40+index), and the ITF's own repair re-syncs all 24 from the ports
  // (BANK4@0xFC824-0xFC87D). A real machine's cells hold exactly that image: the Xa7C9W
  // capture behind qemu-pc98's memsw.inc carries code 0x01 lines 0x00-0x0B as its bank-A
  // image and lines 0x20-0x2B as its bank-B image.
  //
  // The BYTES are the machine's DIP configuration, the one image sdip_powerup carries in
  // pc9821_iobus.sv (this is a second copy because the two stores are in different
  // modules; tb_pc9821_gdc_text pins both spellings to the same capture rows):
  //   bank A = docs/probes/PORTS.TXT:258 (841E 7C 851E 02 861E 76 871E 3E) ...
  //   bank B = the firmware's own factory table (BANK4@0x4818: 8f 80 80 80 80 80 ...)
  // Byte layout of the literal below is store 0x40 first: 12 bank-B bytes, the 4-cell
  // 0x4C..0x4F hole (NO source: the Xa7C9W capture has no code-0x01 rows 0x2c-0x2f, and
  // neither the accessor table nor FC42D/FC824 visit it - zero is its unmeasured
  // power-up, and the walk below skips it), then 12 bank-A bytes.
  localparam [223:0] CG_MIRROR_BYTES =
      224'h9849_7f7f_bfff_7f7c_3e76_027c_0000_0000_8080_8080_8080_8080_8080_808f;

  // ONE walk covers both runs: 38 steps, the record FIRST (it is what the ITF's 0xFC681
  // check reads, so the boot-critical bytes land in the walk's first 14 cycles), then the
  // mirror's 24 sourced bytes. The 24-cycle sdip walk in pc9821_iobus keeps cpu_reset_req
  // high and pc9821_cpu_reset_gate re-arms its 15-cycle hold on each of those cycles, so
  // the CPU may not leave reset before cycle 24+15 = 39 - which covers 38 steps with one
  // cycle of margin. If the walk is ever grown past 38 steps, the hold must grow with it
  // (export this walk's busy into cpu_reset_req) or that invariant is silently gone.
  localparam [5:0]   CG_RESTORE_LEN  = 6'd38;
  localparam [5:0]   CG_RESTORE_LAST = CG_RESTORE_LEN - 6'd1;
  function automatic [12:0] cg_restore_addr(input [5:0] idx);
    begin
      if (idx < 6'd14)       cg_restore_addr = CG_RECORD_ADDR + {9'd0, idx[3:0]};
      else if (idx < 6'd26)  cg_restore_addr = 13'h040 + {7'd0, (idx - 6'd14)};
      else                   cg_restore_addr = 13'h050 + {7'd0, (idx - 6'd26)};
    end
  endfunction
  function automatic [7:0] cg_restore_byte(input [5:0] idx);
    // A byte position in CG_MIRROR_BYTES (0..27). 32 bits wide because pos*8 is the
    // part-select base and is self-determined: at 6 bits it would wrap from 216 to 0.
    reg [31:0] pos;
    begin
      if (idx < 6'd14) begin
        cg_restore_byte = cg_record_byte(idx[3:0], model_xe);
      end else begin
        pos = (idx < 6'd26) ? {26'd0, (idx - 6'd14)} : {26'd0, (idx - 6'd26)} + 32'd16;
        cg_restore_byte = CG_MIRROR_BYTES[pos*8 +: 8];
      end
    end
  endfunction

  // The record restore: a one-cycle strobe from pc9821_iobus starts the 38-byte walk, one
  // byte per clk_sys, through the array's only write port. That port is shared with the
  // 0xA9 access and the 0xA4000 window, so a step needs a cycle none of them uses. A
  // second write port on the scanout side cost 117,521 nodes and 65,552 registers.
  // ONE SOURCE, ONE WALK: the MACHINE-RESET seed (`sdip_seed_pulse`, one cycle at the reset
  // ASSERTION). The seed is why the walk state is NOT under `!rst_n_sys` below: this module's reset is clamped
  // for the whole machine-reset window (`rst_n_sys = !(reset || !cpu_run)` in pc9821_system),
  // so a reset-held walk could not run AT ALL in the window it exists for - it would have to
  // wait for the release, which is the very instant the CPU starts issuing. Held only by its
  // own `initial` values instead, the walk runs inside the window (all three port-sharing
  // conditions - `cg_we`, `cg_rd_win`, `io_rd` - are idle there), so the 38 bytes are written
  // before the CPU can leave its own reset and read the record at 0xFC681. A reset landing
  // mid-walk simply lets the walk finish; the restore is idempotent. WHAT IT WRITES: the
  // record rows are the model table (the guest's READ of them is the static view below, so
  // this half exists for the SCANOUT's copy of the same cells), and the mirror's 24 bytes are
  // live guest state BANK4@0xFC42D copies into the software-DIP ports.
  reg         cg_rec_busy;
  reg  [5:0]  cg_rec_idx;
  /* verilator lint_off PROCASSINIT */   // the initialisers are the registers' power-up values
  initial begin
    cg_rec_busy = 1'b0;
    cg_rec_idx  = 6'd0;
  end
  /* verilator lint_on PROCASSINIT */
  wire        cg_rec_step = cg_rec_busy && !cg_we && !cg_rd_win && !io_rd;
  wire [12:0] cg_rec_addr = cg_restore_addr(cg_rec_idx);
  wire  [7:0] cg_rec_data = cg_restore_byte(cg_rec_idx);

  always @(posedge clk_sys) begin
    if (cg_record_restore) begin
      cg_rec_busy <= 1'b1;
      cg_rec_idx  <= 6'd0;
    end else if (cg_rec_step) begin
      if (cg_rec_idx == CG_RESTORE_LAST) cg_rec_busy <= 1'b0;
      else                               cg_rec_idx  <= cg_rec_idx + 6'd1;
    end
  end

  // ---------------------------------------------------------------
  // THE CONFIGURATION IMAGE - owns every decoder line.
  // The ITF reads the machine's CPU mode and its extended-memory size out of this same
  // battery-backed store, and on the machine they are there before the guest runs; this array
  // powers up blank, so the ITF walks the extended memory past the end of RAM and prints
  // MEMORY ERROR. Six cells: 0x0497 (code 0x1256) the mode byte, where bit 2 clear is the
  // branch the ITF names normal (@0xF95F3); 0x1CA7 (code 0x7257 row 0x27) the image-present
  // flag, which the ITF's own copy block writes as 0x28 (@0xF8DC8) and requires non-zero
  // (@0xF8A62); and 0x1C67/0x1C6D/0x1C6E/0x1C6F (code 0x7157 rows 0x27, 0x2D-0x2F) the size,
  // decoded at @0xF8BD7, @0xF8ECD-0xF8EEC and @0xF8EEE-0xF8F02. Plus the 14 software-DIP
  // record cells 0x810..0x81D (code 0x2056, cg_lr = 1, rows 0..0xD): the stage-1A KANJI
  // CG-RAM test (@0xF8061-0xF80F4) writes 0FFh/00h over the whole store and never restores
  // it, and the ITF re-POSTs (`out 0xF0`) and re-runs the drive probe at @0x1BB6 AFTER the
  // wipe, so without the fallback record byte 0x815 reads 0x00 and [0:59A] becomes 600
  // instead of 0.
  //
  // A STATIC READ-ONLY VIEW over the array for the CPU's READ, not a store into it: what
  // the guest reads from a covered cell is the
  // configuration, whatever it wrote there, because the machine's own battery-backed record
  // cells behave so - the Xa7C9W runtime capture holds the record intact at code 0x2056 rows
  // 0..0xD after its boot's stage-1A wipe (qemu-pc98 roms/pc98bios/memsw.inc). The
  // configuration the CPU sees is therefore static, and the EMM386 fix's fallback is
  // structural: record byte 0x815 always reads 0xFF and [0:59A] = table[15]*600 = 0 exactly
  // as on the machine.
  //
  // THE VIEW IS READ-SIDE ONLY: a guest write still COMMITS to the RAM, which is the text
  // scanout's copy of these cells. They are also ordinary user-character cells - store
  // 0x810..0x81D is the right half of code 0x7620 and 0x0497 a row of 0x7612 - and a guest
  // that defines those characters must see them drawn. Flame Zapper Kotsujin does exactly
  // that: GJLOAD loads 128 glyphs at DX = 0x7620..0x769F through INT 18h AH=1Ah (whose
  // Xe10 BIOS body, F000:EBD7, writes the 0xA4000 window with no code-range check) and the
  // game draws every SPACE as 0x7620, so a gate that dropped those writes would draw the
  // record bytes as the right half of every space (tb_pc9821_cg_gaiji_record). The machine-reset walk below rewrites the record cells, so
  // the RAM copy is the record again at every boot.
  //
  // THE ONE EXCEPTION IS THE READ ECHO: the stage-1A KANJI
  // CG-RAM test (@0xF8061-0xF80F4) sweeps the store with `stos`/`scasb` and compares every
  // byte it wrote back, so a cell that ALWAYS answered its configured byte would fail the
  // comparison and print KANJI CG RAM ERROR (message BANK4@0x2AD5). A "written this pass"
  // mark per cell makes the read answer the RAM - the guest's own last write - while it is
  // set. The mark clears at machine reset and at the ITF's own `out 0xF0` re-POST
  // (cfg_seed_reload = pc9821_iobus's cpu_reset_req), so after the re-POST the record check and drive probe read the static
  // OSD config again. The configuration the CPU reads stays the seed; only the echo is
  // transient.
  // ---------------------------------------------------------------
  localparam [4:0] CFG_SEED_LEN = 5'd20;
  wire [7:0] cfg_mib8 = {1'b0, cfg_ram_mib_eff};
  function automatic [12:0] cfg_seed_addr(input [4:0] idx);
    reg [3:0] rec_idx;
    begin
      case (idx)
        5'd0: cfg_seed_addr = 13'h0497;
        5'd1: cfg_seed_addr = 13'h1CA7;
        5'd2: cfg_seed_addr = 13'h1C67;
        5'd3: cfg_seed_addr = 13'h1C6D;
        5'd4: cfg_seed_addr = 13'h1C6E;
        5'd5: cfg_seed_addr = 13'h1C6F;
        // idx 6..19 are the 14 record cells at store 0x810 + (idx-6). The
        // 4-bit subtraction wraps for idx 16..19 (0..3 - 6 = 10..13), which is
        // exactly idx-6 in 0..13.
        default: begin
          rec_idx = idx[3:0] - 4'd6;
          cfg_seed_addr = CG_RECORD_ADDR + {9'd0, rec_idx};
        end
      endcase
    end
  endfunction
  function automatic [7:0] cfg_seed_byte(input [4:0] idx);
    reg [3:0] rec_idx;
    begin
      case (idx)
        5'd0: cfg_seed_byte = 8'h01;
        5'd1: cfg_seed_byte = 8'h28;
        5'd2: cfg_seed_byte = (cfg_ram_mib_eff >= 7'd16) ? 8'hF0
                                                      : ((cfg_mib8 - 8'd1) << 4);
        5'd3: cfg_seed_byte = (cfg_ram_mib_eff >= 7'd16) ? 8'h78
                                                      : ((cfg_mib8 - 8'd1) << 3);
        5'd4: cfg_seed_byte = (cfg_ram_mib_eff > 7'd16) ? (cfg_mib8 - 8'd16) : 8'h00;
        5'd5: cfg_seed_byte = (cfg_ram_mib_eff > 7'd16) ? ((cfg_mib8 - 8'd16) >> 8) : 8'h00;
        // Record byte idx-6, as above: the model table with the computed checksum.
        default: begin
          rec_idx = idx[3:0] - 4'd6;
          cfg_seed_byte = cg_record_byte(rec_idx, model_xe);
        end
      endcase
    end
  endfunction

  // The seeded cell a CG-RAM address names: {hit, cell index}. The cells are distinct, so the
  // decode is one-hot by construction. Fourteen of the twenty are the record at CG_RECORD_ADDR
  // (cells 6..19 = record byte 0..13), one contiguous run decoded by a range and an offset, not by
  // fourteen full-width compares (tools/equiv/cg_seed_decode.sv proves it equal to the compare
  // against cfg_seed_addr(j) for every address).
  function automatic [5:0] cfg_seed_dec(input [12:0] a);
    begin
      if ((a[12:4] == CG_RECORD_ADDR[12:4]) && (a[3:0] <= 4'd13))
        cfg_seed_dec = {1'b1, 1'b0, a[3:0]} + 6'd6;
      else begin
        case (a)
          13'h0497: cfg_seed_dec = {1'b1, 5'd0};
          13'h1CA7: cfg_seed_dec = {1'b1, 5'd1};
          13'h1C67: cfg_seed_dec = {1'b1, 5'd2};
          13'h1C6D: cfg_seed_dec = {1'b1, 5'd3};
          13'h1C6E: cfg_seed_dec = {1'b1, 5'd4};
          13'h1C6F: cfg_seed_dec = {1'b1, 5'd5};
          default:  cfg_seed_dec = 6'd0;
        endcase
      end
    end
  endfunction
  wire [5:0] cfg_seed_rd = cfg_seed_dec(cg_rd_addr);
  // THE READ ECHO (the KANJI CG-RAM test's write-then-read). A "written this pass" mark per
  // covered cell: while it is set the CPU's read answers the RAM - which holds the guest's
  // own last write, because guest writes commit (see above) - so the KANJI test's
  // `stos`/`scasb` wipe reads back its own 0FFh/00h instead of the static record bytes and
  // does not print KANJI CG RAM ERROR. The mark is cleared at machine reset and at the ITF's
  // `out 0xF0` re-POST (cfg_seed_reload = pc9821_iobus's cpu_reset_req), after which the read
  // is the static configuration again. (The restore walk writes the RAM only inside the
  // machine-reset window, where every mark is held clear, so a set mark always names a
  // guest byte.)
  reg [CFG_SEED_LEN-1:0] cfg_wt_written;            // "written this pass", per cell
  wire [5:0] cfg_seed_wr = cfg_seed_dec(cg_wr_addr);
  /* verilator lint_off PROCASSINIT */   // the initialisers are the registers' power-up values
  initial begin
    cfg_wt_written = {CFG_SEED_LEN{1'b0}};
  end
  /* verilator lint_on PROCASSINIT */
  always @(posedge clk_sys) begin
    if (!rst_n_sys || cfg_seed_reload) begin
      cfg_wt_written <= {CFG_SEED_LEN{1'b0}};
    end else if (cg_we && cfg_seed_en) begin
      if (cfg_seed_wr[5]) cfg_wt_written[cfg_seed_wr[4:0]] <= 1'b1;
    end
  end
  // Only one can match: the twenty addresses are distinct.
  wire [4:0] cfg_seed_sel = cfg_seed_rd[4:0];   // a don't-care without a hit, which gates every use below
  /* verilator lint_off PROCASSINIT */   // the initialisers are the registers' power-up values
  reg        cfg_seed_hit_q = 1'b0;
  reg  [7:0] cfg_seed_read_q = 8'd0;
  /* verilator lint_on PROCASSINIT */
  // The echo's mark, registered on the SAME edge as the seed hit and the RAM's own read so all
  // three answer on one cycle: cfg_seed_hit_q names the cell, and the byte is the RAM's (the
  // guest's last write) when the mark is set, else the static seed byte.
  /* verilator lint_off PROCASSINIT */   // the initialisers are the registers' power-up values
  reg        cfg_wt_hit_q = 1'b0;
  /* verilator lint_on PROCASSINIT */
  always @(posedge clk_sys) begin
    // The compare is registered so that the fallback and the array answer on the SAME cycle:
    // pc9821_dpram's q_a is a registered read, and cg_ram_q must stay one.
    cfg_seed_hit_q  <= cfg_seed_en && cfg_seed_rd[5];
    cfg_seed_read_q <= cfg_seed_byte(cfg_seed_sel);
    cfg_wt_hit_q    <= cfg_wt_written[cfg_seed_sel];
  end
  assign cg_ram_q = (cfg_seed_hit_q && !cfg_wt_hit_q) ? cfg_seed_read_q : cg_ram_read;

  // Port A with the restore folded in. The guest views keep priority, so a step
  // only ever takes a cycle they left idle; the read-during-write path below
  // returns the restored byte on that cycle, which no guest is sampling.
  // Every guest write commits, the configuration cells included (the view above is
  // read-side only).
  wire        cg_do_write = cg_we;
  wire        cg_port_we   = cg_do_write || cg_rec_step;
  wire [12:0] cg_port_addr = cg_do_write ? cg_wr_addr :
                             (cg_rec_step ? cg_rec_addr : cg_rd_addr);
  wire  [7:0] cg_port_din  = cg_do_write ? cg_wr_data : cg_rec_data;

  pc9821_dpram #(
      .AW(13),
      .DW(8),
      // The software-DIP configuration record the authentic ITF validates before it
      // will boot, at store 0x810..0x81D = {code[14:8], code[0], lr, row} for the code
      // 0x2056 it selects: rows 0..0xD with cg_lr = 1. Battery-backed on the machine,
      // so it is there before the guest runs; this array powers up zeroed, which is why
      // a cold core failed the 0xFC681 check. CG_RECORD_INIT is the Xe10 model's row
      // table (cg_record_byte(idx, 1'b0) evaluated: the guest READS these cells through
      // the static view, so the RAM copy is the SCANOUT's and the reset walk rewrites it
      // with the selected model's rows). The ITF reads the record as ES = 0xA400 window
      // offsets 3,5,..,0x15.
      .INIT_EN(1'b1),
      .INIT_BYTES({144'd0, CG_RECORD_INIT}),
      .INIT_LEN(14),
      .INIT_OFFSET(13'h810),
      // The DIP port mirror (see CG_MIRROR_BYTES above): 28 bytes at 0x40..0x5B,
      // the 24 sourced DIP-image bytes plus the unmeasured 0x4C..0x4F hole as zero.
      .INIT2_EN(1'b1),
      .INIT2_BYTES({32'd0, CG_MIRROR_BYTES}),
      .INIT2_LEN(28),
      .INIT2_OFFSET(13'h040)
  ) u_cg_ram (
      .clock_a(clk_sys), .address_a(cg_port_addr), .data_a(cg_port_din),
      .wren_a(cg_port_we), .q_a(cg_ram_read),
      .clock_b(clk_sys), .en_b(pixel_ce), .address_b(cg_ram_vid_addr),
      .data_b(8'h00), .wren_b(1'b0), .q_b(cg_ram_vid_q)
  );


  // The CPU-side JIS byte comes from the fetched glyph block, never from a store: the SDRAM
  // block is the only copy of the JIS grid. The block is usable only once its
  // 8-dword burst has landed; until then the byte is not yet this code's, so the read WAITS
  // rather than answer the previous code. The machine's own
  // CG-ROM read is synchronous, so stalling the guest is the correct model - it can never
  // see a glyph it did not select. The ANK byte stays synchronous in the ANK store.
  //
  // ---- the block RAM's two read ports ----
  // One port per reader; both indexes are 5 bits {page/half, row} into the 32 bytes, and the
  // 8-word memory is addressed by the top three of them with the low two registered beside it
  // as the byte select (the standard shape, and the one that infers). The window's page bit is
  // the class's: ver0.78 takes the block's low page, the wide rows the half register, and every
  // other two-byte row the byte position's own page. One index, one read, for what the flop form
  // expressed as three calls with different constants - measured free (tools/res_exp_map.py,
  // 115 ALUTs either way).
  wire [4:0]  cg_blk_idx     = {cg_lr, cg_line[3:0]};
  wire        cg_win_blk_pg  = cg_ver078 ? 1'b0 : (cg_wide ? cg_lr : win_page);
  wire [4:0]  cg_win_blk_idx = {cg_win_blk_pg, win_row};
  reg  [31:0] cg_port_word_q, cg_win_word_q;
  reg  [1:0]  cg_port_byte_q, cg_win_byte_q;
  always @(posedge clk_sys) begin
    cg_port_word_q <= cg_blkm[cg_blk_idx[4:2]];
    cg_port_byte_q <= cg_blk_idx[1:0];
    cg_win_word_q  <= cg_blkm[cg_win_blk_idx[4:2]];
    cg_win_byte_q  <= cg_win_blk_idx[1:0];
  end
  // THE PORT'S OPEN CYCLE. A registered read is one cycle behind a write, so the cycle a burst
  // beat writes a word is the one cycle the port must not open on: the read register still
  // holds the PRE-write word there, and pc9821_iobus samples the byte on the cycle cg_rd_hold
  // drops (S_DEVWAIT), so an open port is a promise that the byte is this code's. The rule is
  // therefore "open once the memory's own read has caught up", i.e. cg_blk_here one cycle
  // later: `blk_wr_q` is exactly "a beat wrote the block on the previous edge".
  //
  // ONLY THE BURST'S LAST BEAT CAN MATTER, which is what bounds the cost to one cycle per glyph
  // change: cg_blk_here needs !fnt_act, so it is false for the whole burst and the mid-burst
  // beats of a block already being fetched cannot make the port flicker. The one exception the
  // qualification buys is the scanout walker's own fmem beats, which raise font_word_valid
  // while fnt_act is false (the block write and this flag both require fnt_act, so neither acts
  // on them).
  //
  // The cost is ONE device-wait cycle on the FIRST port-0xA9 read after a glyph change - the
  // read that is already pending when the last beat lands - and nothing else: a read that
  // arrives once the hold has dropped sees no wait at all, the 0xA4000 window is NOT extended
  // (its capture is a cycle later again: the window responder's S_READ_WAIT -> S_READ_CAPTURE, so
  // cg_win_word_q has caught up by then), and no other access class touches this hold
  // (pc9821_system gates it to the 0xA9 port). The machine's own cost for that class is ~15.3
  // clk_a = 826 ns (docs/probes/IO.TXT, the 61-port "every other class" arm - 0xA9 itself is
  // not in that census) against this core's 80 ns, so one 20 ns cycle stays far under it.
  //
  // The alternative that trades the other way is the flop form this replaced: the last beat's
  // word (32 flops) plus its index (3) and a valid (1) beside the memory, muxed in against the
  // reader's own index, which lets the port open on the landing cycle and still present the
  // current byte. That is trade candidates T12: ~55 ALMs / 35 registers module-alone for this
  // one cycle. tb_pc9821_font_fetch asserts both halves of the contract on all 32 positions.
  reg blk_wr_q;
  always @(posedge clk_sys) blk_wr_q <= fnt_act && font_word_valid;
  // The memory's own path uses the registered word and byte select TOGETHER; nothing mixes a
  // current index with a registered read.
  wire  [7:0] cg_port_blk_byte = cg_port_word_q[{cg_port_byte_q, 3'b000} +: 8];
  wire  [7:0] cg_win_blk_byte  = cg_win_word_q[{cg_win_byte_q, 3'b000} +: 8];
  wire        cg_blk_here = cg_jis && !fnt_act && (fnt_base_r == cg_jis_base);
  wire  [7:0] cg_jis_port_data = cg_port_blk_byte;
  assign cg_rd_hold = cg_jis && (!cg_blk_here || blk_wr_q);

  // ---- the port 0xA9 read ----
  // The four arms in cgrom_ia9's own branch order (io/cgrom.c:193-226): the ver0.78
  // test (unmasked low byte) first, then the two-byte classes (gaiji store, or the JIS
  // block half by 0xA5 bit 5 - which for ver0.78 with the half CLEAR is the block byte
  // for ANK/ver0.78 and, for the two-byte classes that take a half, 0xA5 bit 5 times 16
  // plus the row), then the ANK table gated by 0xA5 bit 4. cg_p_blank covers both of
  // NP2kai's zero returns (see its definition above).
  wire [7:0] cg_pattern = cg_gaiji      ? cg_ram_q :
                          cg_p_ank      ? (cg_line[4] ? 8'h00 : cg_ank_port_byte) :
                          cg_p_blank    ? 8'h00 :
                                          cg_jis_port_data;

  // ---- the window read ----
  //
  // The window byte, by class. NP2kai's cgwindowset: even offsets are the "low" page,
  // odd offsets the "high" page, row = addr[4:1]; classes that give the low page no
  // meaning leave it on THE dummy - ONE page (cgrom.c:18 `low = 0x7fff0`) shared by
  // every class and both pages of ver0.78+lr (cgrom.c:33-36 `high = low`), so the dummy
  // byte is CLASS-INDEPENDENT. THIS MACHINE ANSWERS 0x8F THERE: the odd page reads
  // 0x00 for all eight rows, so the even page cannot be the store, and the even writes
  // were dropped, so it is read-only (docs/probes/VRAM.TXT). The machine outranks
  // NP2kai's zeroed array byte.
  // UNMEASURED: whether that page is a CONSTANT or a page keyed on the code register -
  // both captures used the same code (0xA1=0x2F, 0xA3=0x57, the gaiji class). 0x8F is
  // measured right for that one state and is what every class answers here; 0x00 is
  // measured right for none.
  localparam [7:0] CG_LOW_DUMMY = 8'h8F;
  reg  [7:0] cg_win_byte_r;
  always @(*) begin
    if (cg_gaiji)          cg_win_byte_r = win_page ? cg_ram_q : CG_LOW_DUMMY;
    // cgwindowset's ONE-BYTE branch (cgrom.c:21-25) is the ANK page for every low byte,
    // 0x09-0x0B included - the port's unmasked ver0.78 class does not exist here.
    else if (!cg_two_byte) cg_win_byte_r = win_page ? cg_ank_win_byte : CG_LOW_DUMMY;
    else if (cg_ver078)    cg_win_byte_r = (win_page && !cg_lr)
                                         ? cg_win_blk_byte : CG_LOW_DUMMY;
    else if (cg_wide)      cg_win_byte_r = win_page
                                         ? cg_win_blk_byte : CG_LOW_DUMMY;
    else                   cg_win_byte_r = cg_win_blk_byte;
  end
  assign cg_win_dout = cg_win_byte_r;
  // The window's two-byte non-gaiji pages read the block too, so the responder waits
  // while the code's burst is in flight (pc9821_window_responder holds S_READ_WAIT). ANK and
  // gaiji answer synchronously.
  assign cg_win_byte_hold = cg_jis && !cg_blk_here;

  // ---------------------------------------------------------------
  // THE ANK TABLE STAYS IN M10K. The 4 KiB 8x16 table (pack 0x30000 = FONT.ROM[0x800:0x1800],
  // 2048 words) is read on every ANK dot and on the CPU's ANK reads (port 0xA9 and the
  // window), and it is small (4 M10K blocks). The JIS grid is NOT here: it lives in the
  // pack's SDRAM copy and is served by the row cache below, which saves the ~276 M10K blocks
  // a full FONT.ROM store would need. DEPTH is explicit so the
  // array is exactly 2048 words.
  // ---------------------------------------------------------------
  localparam integer JIS_ROWS  = 92;
  localparam integer ANK_WORDS = 2048;
  localparam integer ANK_AW    = $clog2(ANK_WORDS);   // 11

  // The CPU ANK reads: port 0xA9's register row and the window's own row. The JIS CPU reads
  // do NOT touch this store (the block serves them), so the store's port A carries
  // only the ANK address and the loader.
  wire [ANK_AW-1:0] font_word_addr = cg_rd_win ? cg_ank_win_addr[11:1]
                                               : cg_ank_port_addr[11:1];

  pc9821_dpram #(
      .AW(ANK_AW),
      .DW(16),
      .DEPTH(ANK_WORDS)
  ) u_ank (
      .clock_a(clk_sys),
      .address_a(font_ld_we ? font_ld_addr[ANK_AW-1:0] : font_word_addr),
      .data_a(font_ld_data),
      .wren_a(font_ld_we),
      .q_a(font_cg_word),
      .clock_b(clk_sys),
      .en_b(pixel_ce),
      .address_b(ank_rd_addr),
      .data_b(16'h0000),
      .wren_b(1'b0),
      .q_b(ank_word)
  );

  // ---------------------------------------------------------------
  // The JIS row cache. The scanout's read address is packed the same way as the walker's
  // write address: bank*320 + cell*4 + word, with the three fields arriving from
  // pc9821_crtc's fetch state. The read is the same one-cycle registered read u_font's
  // port B had.
  // ---------------------------------------------------------------
  /* verilator lint_off WIDTHEXPAND */  // the packed address is value-bounded (bank<=2, cell<=79, word<=3 -> <= 959 < 1024),
  /* verilator lint_off WIDTHTRUNC */    // so the 32-bit product widths and the truncation to JC_AW are both intentional
  wire [JC_AW-1:0] jc_rd_addr = jc_rd_bank * JC_BANK + {jc_rd_cell, 2'b00} + jc_rd_word;
  /* verilator lint_on WIDTHEXPAND */
  /* verilator lint_on WIDTHTRUNC */
  wire [31:0] jc_wr_q_unused;
  pc9821_dpram #(
      .AW(JC_AW), .DW(32), .DEPTH(JC_DEPTH)
  ) u_jis_cache (
      .clock_a(clk_sys), .address_a(wk_wr_addr), .data_a(wk_wr_data),
      .wren_a(wk_wr_en), .q_a(jc_wr_q_unused),
      .clock_b(clk_sys), .en_b(pixel_ce), .address_b(jc_rd_addr),
      .data_b(32'h0000_0000), .wren_b(1'b0), .q_b(jc_rd_q)
  );

  // The row-cache bank invariant, in the module's simulation-only style: it asserts
  // that the walker fills the bank the scanout is not reading, on every JIS frame that
  // wraps a bank.
  // (The walker finishes a row in ~1.5 scanlines, so its writes are long done by the last cell,
  // the one dot where the scanout legitimately reads the walker's bank.)
`ifdef VERILATOR
  always @(posedge clk_sys)
    if (wk_wr_en && (wk_bank == jc_rd_bank))
      $error("pc9821_cg: the row-cache walker wrote the bank the scanout is reading (wk_row=%0d)",
             wk_row);
`endif

  // ---- the row-cache walker ----
  // It fills the bank for the NEXT text row while the scanout draws the current one. It
  // borrows the TRAM port on the dot the scanout's fetch does not use (the scanout reads the
  // code planes on dots 3/4/5; the walker reads on dot 0, so the two can never collide). It
  // has a whole text row - 16 scanlines - to walk the row's 80 cells, so it need not keep
  // pace: two dot-0 TRAM reads per cell plus one 8-dword burst. The burst's four kept dwords
  // (the cell's half) go straight into the cache on the font_word_valid beats.

  wire [2:0] adot = hdot[2:0];
  wire wk_two    = |wk_code_hi;
  wire wk_gaiji  = wk_two && (((wk_code_lo & 8'h7F) == 8'h56) ||
                              ((wk_code_lo & 8'h7F) == 8'h57));
  wire wk_ver078 = (wk_code_lo[6:0] >= 7'h09) && (wk_code_lo[6:0] < 7'h0c);
  // The row-cache classes, the scanout's own decode (NP2kai maketext.c:278-296): every
  // two-byte non-gaiji cell draws from the block at (kc & 0x7f7f) << 4. The kanji pairs
  // consume two cells; the ver0.78 rows kc 0x09-0x0B draw the slot's LEFT half alone
  // (maketext.c:292-294 leaves kanji2nd clear for them) - the half-width glyph.
  wire wk_jis_any  = wk_two && !wk_gaiji;
  wire wk_jis_pair = wk_jis_any && !wk_ver078;
  wire [7:0] wk_ku  = {1'b0, wk_code_lo[6:0]} - 8'h01;
  wire [7:0] wk_ten = {1'b0, wk_code_hi[6:0]} - 8'h20;
  wire wk_row_in   = (wk_ku < JIS_ROWS[7:0]);
  // A right half reuses the pair's row/column and ignores its own code - the scanout's own
  // rule - and the pair never crosses the line, so a left half in the last cell leaves none.
  wire wk_new_pair = wk_jis_pair && wk_row_in && !wk_jis2nd;
  // A ver0.78 row is a SINGLE: one fetch of the slot, half 0 (the base/left 16 bytes),
  // and no pair left behind for the next cell.
  wire wk_half_cell = wk_jis_any && wk_ver078 && wk_row_in && !wk_jis2nd;
  wire [7:0] wk_use_row = wk_jis2nd ? wk_pair_row : wk_ku;
  wire [7:0] wk_use_ten = wk_jis2nd ? wk_pair_ten : wk_ten;
  wire wk_fetch = wk_new_pair || wk_jis2nd || wk_half_cell;
  wire [18:0] wk_glyph_next = 19'h1800 + {wk_use_row, 11'b0} + {1'b0, wk_use_row, 10'b0}
                            + {6'd0, wk_use_ten, 5'b0};

  // The walker's TRAM address, COMBINATIONAL from its state so it is on pc9821_crtc's port
  // DURING dot 0 - a registered one would arrive a dot late and read the scanout's default.
  /* verilator lint_off UNUSEDSIGNAL */  // only bits [11:0] are the TRAM word; the sum's top bits are the wrap the slice drops
  wire [15:0] wk_wordidx = {6'd0, wk_row} * {8'd0, v_pitch}
                         + (v_col40 ? {8'd0, wk_cell, 1'b0} : {9'd0, wk_cell})
                         + wk_sad;
  /* verilator lint_on UNUSEDSIGNAL */
  wire [13:0] wk_lo_addr = {1'b0, wk_wordidx[11:0], 1'b0};
  wire [13:0] wk_hi_addr = {1'b0, wk_wordidx[11:0], 1'b1};
  assign wk_tr_read = ((wk_state == W_LO) || (wk_state == W_HI)) && (adot[2:0] == 3'd0);
  assign wk_tr_addr = (wk_state == W_HI) ? wk_hi_addr : wk_lo_addr;

  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      wk_state <= W_IDLE; wk_cell <= 7'd0; wk_row <= 10'd0; wk_sad <= 16'd0; wk_bank <= 2'd0;
      wk_req <= 1'b0; wk_act <= 1'b0; wk_beat <= 3'd0;
      wk_wr_en <= 1'b0; wk_wr_addr <= {JC_AW{1'b0}}; wk_wr_data <= 32'd0;
      wk_glyph_r <= 19'd0; wk_half_r <= 1'b0;
      wk_code_lo <= 8'd0; wk_code_hi <= 8'd0;
      wk_jis2nd <= 1'b0; wk_pair_row <= 8'd0; wk_pair_ten <= 8'd0;
      wk_skip_cnt <= 16'd0;
    end else begin
      wk_wr_en <= 1'b0;

      // Start a walk on the first dot of a text row's first scanline, filling the bank for
      // the NEXT row. A walk already in flight is not restarted - and that silently SKIPS the
      // slot's row, so the skip is counted (saturating) rather than dropped.
      // Row 0's fill is re-aimed at the vline-432 slot when a configuration change has left its
      // last-row fill with the previous frame's display start (pc9821_crtc's stale_slot, I2).
      if (pixel_ce && wk_go && (hdot == 10'd0)) begin
        if (wk_state == W_IDLE) begin
          wk_row   <= wk_k;
          wk_sad   <= v_sad;
          wk_bank  <= wk_bank_in;
          wk_cell  <= 7'd0;
          wk_jis2nd <= 1'b0;
          wk_state <= W_LO;
        end else if (wk_skip_cnt != 16'hFFFF) wk_skip_cnt <= wk_skip_cnt + 16'd1;
      end

      // The grant: the port arbiter picked the walker, so latch the burst's owner state.
      if (start_wk) begin
        wk_act  <= 1'b1;
        wk_beat <= 3'd0;
        wk_req  <= 1'b0;
      end

      // Burst beats: keep only the four dwords of the cell's half.
      if (wk_act && font_word_valid) begin
        if (wk_beat[2] == wk_half_r) begin
          wk_wr_en   <= 1'b1;
          wk_wr_addr <= wk_wr_off;
          wk_wr_data <= font_word_data;
        end
        if (wk_beat == 3'd7) begin
          wk_act <= 1'b0;
          if (wk_cell == 7'd79) wk_state <= W_IDLE;
          else begin wk_cell <= wk_cell + 7'd1; wk_state <= W_LO; end
        end else wk_beat <= wk_beat + 3'd1;
      end

      case (wk_state)
        W_LO:  if (pixel_ce && (adot[2:0] == 3'd0)) wk_state <= W_LOC;
        W_LOC: if (pixel_ce && (adot[2:0] == 3'd1)) begin
                 wk_code_lo <= tram_vid_q; wk_state <= W_HI;
               end
        W_HI:  if (pixel_ce && (adot[2:0] == 3'd0)) wk_state <= W_HIC;
        W_HIC: if (pixel_ce && (adot[2:0] == 3'd1)) begin
                 wk_code_hi <= tram_vid_q; wk_state <= W_DEC;
               end
        W_DEC: begin
                 if (wk_fetch) begin
                   wk_glyph_r <= wk_glyph_next;
                   wk_half_r  <= wk_jis2nd;          // a right half is the pair's second cell
                   wk_jis2nd  <= (wk_new_pair && (wk_cell != 7'd79));
                   if (wk_new_pair) begin wk_pair_row <= wk_ku; wk_pair_ten <= wk_ten; end
                   wk_req   <= 1'b1;
                   wk_state <= W_REQ;
                 end else begin
                   wk_jis2nd <= 1'b0;
                   if (wk_cell == 7'd79) wk_state <= W_IDLE;
                   else begin wk_cell <= wk_cell + 7'd1; wk_state <= W_LO; end
                 end
               end
        W_REQ: ;   // waits for start_wk, which latches the burst
        default: ;
      endcase
    end
  end

  assign dbg_wk_skips = wk_skip_cnt;

  // ---------------------------------------------------------------
  // CPU-side port reads. This module answers only its own addresses (0xA1/0xA3/0xA5/0xA9);
  // pc9821_system muxes it with pc9821_crtc's and pc9821_gdc2's, and the arm that reaches
  // these three ports is the cg_io_dout one -- pc9821_system.sv:2001 "(device_io_addr[7:0] == 8'hA5) || (device_io_addr[7:0] == 8'" -- so the
  // bytes below are the bytes a CPU read of 0xA1/0xA3/0xA5 receives.
  //
  // The three register ports DO read back their latches. NP2kai attaches a read handler only
  // at index 4 (0xA9, io/cgrom.c:240-243), so open 0xFF would look like a faithful model -
  // but the machine outranks NP2kai, and it drives a byte there in every read-only scan of the real Xe10:
  // `docs/probes/PORTS.TXT` (probe2's tab_latches scan, one byte per port, no writes made)
  // reads `00A1=2F 00A3=57 00A5=0F 00A9=00` with the genuinely open 0xA7/0xAB/0xAD/0xAF beside
  // them all reading FF, and VRAM.TXT / MEMSW.TXT / PIT-fixed.TXT / PITPH.TXT / RDBACK.TXT /
  // WIPE-rerun.TXT repeat the same four bytes (seven captures, all read-only). They are the
  // latches: 0x2F57 is the code the firmware selected and 0x0F is its line, and the machine's
  // own CG window reads in the same capture used that code ("A1=2F, A3=57, the gaiji class").
  // A write-then-read row for the three ports is still the one run that would pin the byte as
  // the register rather than a driven constant (the captures are read-only); until then this
  // returns the latches, which is the only reading that also round-trips a guest's own write,
  // and 0xFF is wrong either way.
  // ---------------------------------------------------------------
  reg [7:0] io_dout_r;
  always @(*) begin
    case (io_addr)
      8'hA1: io_dout_r = cg_code[15:8];
      8'hA3: io_dout_r = cg_code[7:0];
      8'hA5: io_dout_r = {2'b00, ~cg_lr, cg_line};
      8'hA9: io_dout_r = cg_pattern;
      default: io_dout_r = 8'hFF;
    endcase
  end
  assign io_dout = io_dout_r;

  // The CG code and line registers, from ports 0xA1/0xA3/0xA5. A 0xA9 write is decoded
  // beside the storage array (cg_ram_we).
  always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
      cg_code <= 16'h0000;
      cg_line <= 5'd0;
      cg_lr   <= 1'b0;
    end else if (io_wr) begin
      if (io_addr == 8'hA1) cg_code[15:8] <= io_din;   // CG code high
      else if (io_addr == 8'hA3) cg_code[7:0] <= io_din;   // CG code low
      else if (io_addr == 8'hA5) begin                      // CG line + kanji half select
        cg_line <= io_din[4:0];
        cg_lr   <= ~io_din[5];
      end
    end
  end

endmodule

`default_nettype wire
