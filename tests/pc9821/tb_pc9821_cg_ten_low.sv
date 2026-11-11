`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_CG_TEN_LOW: a CPU read of a two-byte CG code whose column byte (0xA1) is 0x01-0x1F answers the glyph of column 0x20 in the same row, as the real Xe10 does (docs/probes/KIT1-XE10-CG0-USERCG.TXT:533-724, the CGX table: for 0xA3 = 0x01, 0x10 and 0x22 every 0xA1 from 0x01 to 0x20 reads 16 zero bytes in both halves, CRC 6A0A, and for 0xA3 = 0x5C every 0xA1 from 0x01 to 0x20 reads 16 0xFF bytes, CRC 6A4B, which is FONT.ROM's column-0x20 slot of each row: all 188 two-byte rows of that table match the column-0x20 address and 119 do not match the wrapped address the core used, docs/probes/core/KIT1-CORE-rc-e6db0f05-s3-CG0.TXT), through port 0xA9 (both halves by 0xA5 bit 5, all 16 rows) and through the 0xA4000 window (the odd bytes, and for the plain JIS rows the even bytes too), for 0xA1 = 0x01, 0x10, 0x1A, 0x1B and 0x1F in rows 0xA3 = 0x01, 0x10, 0x22 and 0x5C, against a font whose every byte is tagged by its own offset; column 0x21 keeps its own slot and the user-CG class 0x56 at 0xA1 = 0x10 (the record code 0x1056) keeps reading the CG RAM, not the font. The window's EVEN page is keyed on the class: it reads 0xFF for a one-byte code (docs/probes/KIT1-XE10-CG0-USERCG.TXT:533 `CGX 0001 P20=A97D P00=A97D W20E=6A4B`; codes 0x0001, 0x0010, 0x0022 and 0x005C, every row, both 0xA5 halves) and for a row 0x5C code (:710 `CGX 215C P20=AB09 P00=4386 W20E=6A4B`), and stays 0x8F for the user-CG code 0x1056 (:518 `CGW 1056 00 8FFF8F02`); and kit 2's rows (docs/probes/KIT2-XE10-CG2-USERCG.TXT, 0xA1 = 0x01, 0x21 and 0x2F, both 0xA5 halves): the even page reads 0xFF in row 0x09 (:758 `CGX 2109 ... W20E=6A4B ... W00O=6A0A`) and row 0x0C (:806 `CGX 210C ... W20E=6A4B`) and 0x8F in row 0x58 (:822 `CGX 0158 ... W20E=A0DD`), not row 0x5C's 0xFF, and row 0x09's odd page with bit 5 clear reads 0x00. FAIL-FIRST: before the kit-2 change rows 0x09 and 0x0C read 0x8F on the even page, row 0x58 0xFF and row 0x09's odd page with bit 5 clear 0x8F (336 mismatching bytes).
//
// ---- the bench's own account of where each expectation comes from ----
// THE CAPTURE. XE10CFG `/CG` on the real Xe10 read 32-byte glyphs for 0xA1 = 0x00..0x2F in four
// rows (0xA3 = 0x01, 0x10, 0x22, 0x5C) through port 0xA9 (P20 = 0xA5 bit 5 set, the left half;
// P00 = clear, the right half) and the 0xA4000 window (W..E/W..O = even/odd bytes), as CRC-16s.
// CRC 6A0A is 16 bytes of 0x00 and 6A4B 16 bytes of 0xFF. Each row's 0xA1 = 0x01..0x1F lines
// carry the same two CRCs as its 0xA1 = 0x20 line - zeros in rows 0x01/0x10/0x22, 0xFF in row
// 0x5C - so the machine reads a column below 0x20 as column 0x20, not a wrapped neighbour:
// `xe10cfg_decode.py --font FONT.ROM` against the user's dump matches every one of the 188
// two-byte rows to the column-0x20 address. The machine's bytes are font content (zero or
// 0xFF), so this bench serves a TAGGED font instead and asserts the ADDRESS: every byte a read
// returns must be the byte at FONT.ROM 0x1800 + (ku - 0x21) * 0xC00 + half * 16 + row, the
// column-0x20 slot (the JIS address function tb_pc9821_cg_read_path proves on the dump's own
// bytes).
// KIT 2 added rows 0x09, 0x0C and 0x58 (docs/probes/KIT2-XE10-CG2-USERCG.TXT): their window
// pages that read a CONSTANT are asserted (the even page in both 0xA5 halves, row 0x09's odd page
// with bit 5 clear); row 0x58's odd page and port reads are unstable on the machine (the window
// and the port disagree on 20 of 48 codes) and are not.
// NOT asserted: the ver0.78 rows 0x0A-0x0B, the wide rows 0x0D-0x0F and rows 0x59-0x5B/0x5D-0x5F
// (not in either capture; todo item 189), and 0xA1 with bit 7 set (not in the capture; the core
// keeps ignoring that bit as it always has).


`default_nettype none

module tb_pc9821_cg_ten_low;
  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;
  reg reset = 1;

  // ---- memory subsystem controls --------------------------------------
  reg [3:0] top_bank = 4'd8;
  reg ide_rom_enable = 0;
  reg bios_ram_gate = 0;
  reg [7:0] win0_sel = 8'h08;
  // 0x043B bit 2, the 15-16 MiB system-space window. The machine's reset value is ON,
  // so these benches drive the same state the card comes up in.
  reg  sys16m_en = 1'b1;
  reg [31:0] pack_base = 32'h01F8_0000;
  reg [31:0] guest_ram_bytes = 32'h0200_0000;
  reg gvram_access_page = 0;
  reg ioctl_download = 0, ioctl_wr = 0;
  reg [15:0] ioctl_index = 0;
  reg [26:0] ioctl_addr = 0;
  reg [15:0] ioctl_dout = 0;
  wire ioctl_wait, rom_ready, load_error, cpu_run;
  wire [10:0] font_addr;
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
  wire [7:0] tram_din, tram_dout;
  wire tram_we;

  // CG byte channel between the subsystem's window responder and the GDC.
  wire [4:0] cg_win_byte_sel;
  wire cg_win_rd;
  wire [7:0] cg_win_dout, cg_win_din;
  wire cg_win_we;

  // Glyph fetch: the GDC's request, and the SDRAM's second port behind it.
  wire [18:0] font_req_addr;
  wire font_req, font_word_valid;
  wire [31:0] font_word_data;
  // The port 0xA9 read wait (the read is held while the glyph's block is fetched).
  wire cg_rd_hold;
  wire [31:0] fmem_addr, fmem_din;
  wire fmem_valid, fmem_write;
  wire [3:0] fmem_be;
  wire [7:0] fmem_burstcount;
  reg fmem_ready = 1, fmem_resp_valid = 0;
  reg [31:0] fmem_dout = 32'd0;

  // Backend (SDRAM port 0) stub: the CPU's memory, unused here.
  wire [31:0] mem_addr, mem_din, mem_din_hi;
  reg [31:0] mem_dout = 32'hDEAD_BEEF;
  reg [127:0] mem_line_dout = 128'h0123_4567_89AB_CDEF_FEDC_BA98_7654_3210;
  wire [3:0] mem_be;
  wire [7:0] mem_burstcount;
  wire mem_line_read, mem_valid, mem_write;
  reg mem_ready = 1, mem_resp_valid = 0, mem_line_resp_valid = 0;

  // ---- the pack's FONT.ROM copy ---------------------------------------
  //
  // A TAGGED font: every byte is a function of its own offset, so the byte a read returns
  // names the address it was fetched from - a read of column 0x20 and a read of any other
  // column answer different bytes.
  localparam [31:0] FONT_PACK_OFFSET = 32'h0008_0000;
  function automatic [7:0] font_byte(input [18:0] off);
    font_byte = off[7:0] ^ (off[15:8] * 8'd7) ^ {5'd0, off[18:16]} ^ 8'h5A;
  endfunction

  wire [31:0] fmem_font = fmem_addr - (pack_base + FONT_PACK_OFFSET);
  wire [18:0] fmem_off  = fmem_font[18:0];

  // A burst's response is a STREAM: `fmem_burstcount` dwords, one resp_valid per dword in
  // address order, the first the cycle after accept. This is the SDRAM's own shape (one
  // dword per clk_sys) and the contract the font port now relies on for its 8-dword glyph
  // fetch; a single-dword responder would leave the eighth beat owed forever.
  reg        fmem_stream = 1'b0;
  reg  [7:0] fmem_left   = 8'd0;
  reg [18:0] fmem_off_q  = 19'd0;
  always @(posedge clk_sys) begin
    fmem_resp_valid <= 1'b0;
    if (fmem_stream) begin
      fmem_dout       <= {font_byte(fmem_off_q + 3), font_byte(fmem_off_q + 2),
                          font_byte(fmem_off_q + 1), font_byte(fmem_off_q)};
      fmem_resp_valid <= 1'b1;
      fmem_off_q      <= fmem_off_q + 19'd4;
      fmem_left       <= fmem_left - 8'd1;
      if (fmem_left == 8'd1) fmem_stream <= 1'b0;
    end else if (fmem_valid && fmem_ready) begin
      fmem_dout       <= {font_byte(fmem_off + 3), font_byte(fmem_off + 2),
                          font_byte(fmem_off + 1), font_byte(fmem_off)};
      fmem_resp_valid <= 1'b1;
      fmem_off_q      <= fmem_off + 19'd4;
      fmem_left       <= fmem_burstcount - 8'd1;
      if (fmem_burstcount > 8'd1) fmem_stream <= 1'b1;
    end
  end

  // ==== DUT ====
  // Two blocks, wired exactly as pc9821_system.sv wires them.
  // The GVRAM datapath's ports: the GRCG's device-bus bytes, and the
  // scanout's read side. Unused here, but the instantiation needs them.
  reg        grcg_we = 0;
  reg  [7:0] grcg_addr = 0;
  reg  [7:0] grcg_din = 0;
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
  // The 16-colour select (port 0x6A FF2 num 0): 0 = the digital mode the machine resets to,
  // where 0xE0000-0xE7FFF is open bus (pc9821_memory_map e_plane_nc).
  reg        mode2_16color = 1'b0;

  pc9821_memory_subsystem dut_mem (
      .mode2_16color(mode2_16color),
      .scan_dot_ce(1'b0), .scan_dot_act(1'b1),
      .clk(clk_sys), .reset(reset),
      .top_bank(top_bank), .ide_rom_enable(ide_rom_enable), .d8_bank(2'b00), .ide_ram_gate(1'b1),
      .bios_ram_gate(bios_ram_gate),
      .win0_sel(win0_sel), .win0_sel_moved(win0_sel != 8'h08),
    .sys16m_en(sys16m_en),
      .pack_base(pack_base), .guest_ram_bytes(guest_ram_bytes),
      .gvram_access_page(gvram_access_page),
      .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
      .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
      .ioctl_wait(ioctl_wait), .rom_ready(rom_ready), .load_error(load_error),
      .cpu_run(cpu_run),
      .font_addr(font_addr), .font_data(font_data), .font_we(font_we),
      .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_dout(cpu_dout),
      .cpu_be(cpu_be),
      .cpu_burstcount(cpu_burstcount), .cpu_line_read(cpu_line_read),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write), .cpu_ready(cpu_ready),
      .cpu_resp_valid(cpu_resp_valid),
      .tram_addr(tram_addr), .tram_din(tram_din), .tram_we(tram_we),
      .tram_dout(tram_dout),
      .cg_win_byte_sel(cg_win_byte_sel), .cg_win_rd(cg_win_rd),
      .cg_win_dout(cg_win_dout), .cg_win_din(cg_win_din), .cg_win_we(cg_win_we),
      .font_req_addr(font_req_addr), .font_req(font_req),
      .font_word_valid(font_word_valid), .font_word_data(font_word_data),
      .fmem_addr(fmem_addr), .fmem_din(fmem_din),
      .fmem_valid(fmem_valid), .fmem_write(fmem_write),
      .fmem_be(fmem_be), .fmem_burstcount(fmem_burstcount),
      .fmem_ready(fmem_ready), .fmem_dout(fmem_dout),
      .fmem_resp_valid(fmem_resp_valid),
      .mem_addr(mem_addr), .mem_din(mem_din), .mem_din_hi(mem_din_hi),
      .mem_dout(mem_dout),
      .mem_be(mem_be),
      .mem_burstcount(mem_burstcount),
      .mem_valid(mem_valid), .mem_write(mem_write), .mem_ready(mem_ready),
      .mem_resp_valid(mem_resp_valid),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .scan_walk_page(scan_walk_page),
      .scan_line_base(scan_line_base),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready)
  );

  // ---- GDC owning the class table, the stores and port 0xA9 -------------
  reg io_wr = 0, io_rd = 0;
  reg [7:0] io_addr = 0, io_din = 0;
  wire [7:0] io_dout;
  wire gfx_access_page_t;
  wire vsync_active, disp_on, vsync_irq;
  reg vsync_irq_arm = 0;
  wire [15:0] dbg_sad;
  wire [7:0] dbg_pitch;
  wire dbg_col40, dbg_disp;
  wire v_hs, v_vs, v_de;

  // The configuration-image seed: a 32 MiB OSD selection, which is the size the tier and the
  // card's own default both use. The values asserted below are the firmware's own decoder
  // inverses for that size.
  reg [6:0] cfg_ram_mib = 7'd32;
  reg       cfg_seed_en = 1'b1;
  // The OSD Machine field's list position for the record's model table (section 0d).
  reg [3:0] bios_set = 4'd0;
  // The ITF's own `out 0xF0` CPU-mode reset, driven by this bench to clear the
  // write-through read echo exactly as the machine's re-POST does.
  reg       cfg_seed_reload = 1'b0;

  pc9821_gdc_text_dut dut_gdc (
      .clk_sys(clk_sys), .rst_n_sys(!reset),
      .cfg_fdd_mode(3'd0),   // entry 0: the measured boot/FDD nibble
      .pixel_ce(1'b1), .cfg_ram_mib(cfg_ram_mib), .cfg_seed_en(cfg_seed_en),
      .cfg_seed_reload(cfg_seed_reload),
      .bios_set(bios_set),
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din),
      .io_dout(io_dout),
      .tram_cpu_addr(tram_addr), .tram_cpu_din(tram_din),
      .tram_cpu_we(tram_we), .tram_cpu_dout(tram_dout),
      .font_ld_addr(font_addr), .font_ld_data(font_data), .font_ld_we(font_we),
      .cg_win_byte_sel(cg_win_byte_sel), .cg_win_rd(cg_win_rd),
      .cg_win_dout(cg_win_dout), .cg_win_din(cg_win_din), .cg_win_we(cg_win_we),
      .font_req_addr(font_req_addr), .font_req(font_req),
      .font_word_valid(font_word_valid), .font_word_data(font_word_data),
      .cg_rd_hold(cg_rd_hold),
      .cg_record_restore(1'b0),
      .vsync_active(vsync_active), .vsync_irq_arm(vsync_irq_arm),
      .vsync_irq(vsync_irq), .disp_on(disp_on), .gfx_access_page(gfx_access_page_t),
      .dbg_sad(dbg_sad), .dbg_pitch(dbg_pitch), .dbg_col40(dbg_col40),
      .dbg_disp(dbg_disp),
      .hs_out(v_hs), .vs_out(v_vs), .de_out(v_de)
  );

  integer errors = 0;
  integer i, r, ai, ri, half;
  reg [7:0] value;
  reg [7:0] want;
  reg [7:0] a1, a3;

  // ==== STIMULUS ====
  task automatic send_word(input [26:0] addr, input [15:0] data);
    begin
      while (ioctl_wait) @(negedge clk_sys);
      @(negedge clk_sys);
      ioctl_addr = addr; ioctl_dout = data; ioctl_wr = 1;
      @(negedge clk_sys); ioctl_wr = 0;
    end
  endtask

  task automatic write_io(input [7:0] portnum, input [7:0] data);
    begin
      @(negedge clk_sys);
      io_addr = portnum; io_din = data; io_wr = 1;
      @(negedge clk_sys); io_wr = 0;
    end
  endtask

  // A port read waits out the glyph fetch exactly as the I/O bus does (cg_rd_hold).
  task automatic read_io(input [7:0] portnum, output [7:0] data);
    begin
      @(negedge clk_sys);
      io_addr = portnum;
      while (cg_rd_hold) @(negedge clk_sys);
      #1 data = io_dout;
      @(negedge clk_sys);
    end
  endtask

  task automatic mem_read_byte(input [31:0] addr, output [7:0] data);
    integer lane;
    begin
      lane = addr[1:0];
      @(negedge clk_sys);
      cpu_addr = addr; cpu_be = 4'hF; cpu_valid = 1; cpu_write = 0;
      cpu_line_read = 0;
      while (!cpu_ready) @(negedge clk_sys);
      while (!cpu_resp_valid && !cpu_line_word_valid) @(negedge clk_sys);
      #1 data = cpu_dout[lane*8 +: 8];
      @(negedge clk_sys); cpu_valid = 0;
      repeat (4) @(negedge clk_sys);
    end
  endtask

  task automatic select_glyph(input [7:0] hi, input [7:0] lo);
    begin
      write_io(8'hA1, hi);
      write_io(8'hA3, lo);
      repeat (4) @(negedge clk_sys);
      while (font_req) @(negedge clk_sys);
      repeat (4) @(negedge clk_sys);
    end
  endtask

  // The byte FONT.ROM holds at column `ten`, row `a3`'s ku, `half` (0 left, 1 right), glyph line `r`.
  function automatic [7:0] slot_byte(input [7:0] ten, input [7:0] lo, input integer hf, input integer rr);
    reg [18:0] off;
    begin
      off = 19'h1800 + ({12'd0, lo[6:0]} - 19'd1) * 19'hC00 + ({11'd0, ten} - 19'h20) * 19'h20
            + hf * 16 + rr;
      slot_byte = font_byte(off);
    end
  endfunction

  // Every row of one code: port 0xA9 both halves, then the window's odd bytes (and, for the
  // plain JIS rows, the even bytes - left half there, the machine's W20E = P20), all against
  // the slot of column `ten_want`.
  task automatic check_code(input [7:0] hi, input [7:0] lo, input [7:0] ten_want);
    reg wide;
    begin
      wide = (lo[6:0] >= 7'h58) && (lo[6:0] < 7'h60);
      select_glyph(hi, lo);
      for (half = 0; half < 2; half = half + 1)
        for (r = 0; r < 16; r = r + 1) begin
          write_io(8'hA5, (half == 0 ? 8'h20 : 8'h00) | r[7:0]);
          read_io(8'hA9, value);
          want = slot_byte(ten_want, lo, half, r);
          if (value !== want) begin
            if (errors < 16)
              $display("FAIL: port 0xA9 code A1=%02x A3=%02x %s row %0d read %02x, column 0x%02x's slot holds %02x (KIT1-XE10-CG0-USERCG.TXT CGX)",
                       hi, lo, half == 0 ? "left" : "right", r, value, ten_want, want);
            errors = errors + 1;
          end
        end
      for (half = 0; half < 2; half = half + 1) begin
        write_io(8'hA5, half == 0 ? 8'h20 : 8'h00);
        for (r = 0; r < 16; r = r + 1) begin
          // odd bytes: the right half for a plain JIS row, the 0xA5-selected half for a wide row
          mem_read_byte(32'h000A_4000 + (r * 2 + 1), value);
          want = slot_byte(ten_want, lo, wide ? half : 1, r);
          if (value !== want) begin
            if (errors < 16)
              $display("FAIL: window odd byte code A1=%02x A3=%02x A5=%02x row %0d read %02x, column 0x%02x's slot holds %02x",
                       hi, lo, half == 0 ? 8'h20 : 8'h00, r, value, ten_want, want);
            errors = errors + 1;
          end
          // even bytes: the left half for a plain JIS row; 0xFF for a row 0x58-0x5F code
          // (KIT1-XE10-CG0-USERCG.TXT:710 `CGX 215C P20=AB09 P00=4386 W20E=6A4B`, 6A4B = 16 x FF)
          mem_read_byte(32'h000A_4000 + (r * 2), value);
          want = wide ? 8'hFF : slot_byte(ten_want, lo, 0, r);
          begin
            if (value !== want) begin
              if (errors < 16)
                $display("FAIL: window even byte code A1=%02x A3=%02x row %0d read %02x, want %02x (%s)",
                         hi, lo, r, value, want, wide ? "the Xe10's 0xFF, CGX xx5C W20E=6A4B" : "column 0x20's slot");
              errors = errors + 1;
            end
          end
        end
      end
    end
  endtask

  // ==== CHECKS ====
  initial begin
    repeat (3) @(posedge clk_sys);
    @(negedge clk_sys);
    reset = 0;
    // Release the CPU side: the pack download's end is what raises rom_ready/cpu_run.
    ioctl_download = 1;
    send_word(27'd0, 16'hBEEF);
    repeat (2) @(posedge clk_sys);
    ioctl_download = 0;
    repeat (3) @(posedge clk_sys);
    if (!cpu_run) begin
      $display("FAIL: cpu_run never asserted after the pack download");
      errors = errors + 1;
    end

    // Columns 0x01-0x1F read as column 0x20 in every captured row.
    for (ri = 0; ri < 4; ri = ri + 1) begin
      a3 = (ri == 0) ? 8'h01 : (ri == 1) ? 8'h10 : (ri == 2) ? 8'h22 : 8'h5C;
      for (ai = 0; ai < 5; ai = ai + 1) begin
        a1 = (ai == 0) ? 8'h01 : (ai == 1) ? 8'h10 : (ai == 2) ? 8'h1A : (ai == 3) ? 8'h1B : 8'h1F;
        check_code(a1, a3, 8'h20);
      end
      // The control: column 0x21 is in the grid and keeps its own slot (CGX 2101/2110/2122/215C
      // match the core's address on the machine).
      check_code(8'h21, a3, 8'h21);
    end

    // One-byte codes: the window's even page reads 0xFF on the Xe10
    // (KIT1-XE10-CG0-USERCG.TXT:533 `CGX 0001 P20=A97D P00=A97D W20E=6A4B`; 0010, 0022, 005C alike).
    for (ri = 0; ri < 4; ri = ri + 1) begin
      a3 = (ri == 0) ? 8'h01 : (ri == 1) ? 8'h10 : (ri == 2) ? 8'h22 : 8'h5C;
      select_glyph(8'h00, a3);
      for (half = 0; half < 2; half = half + 1) begin
        write_io(8'hA5, half == 0 ? 8'h20 : 8'h00);
        for (r = 0; r < 16; r = r + 1) begin
          mem_read_byte(32'h000A_4000 + (r * 2), value);
          if (value !== 8'hFF) begin
            if (errors < 24)
              $display("FAIL: window even byte of one-byte code 00%02x row %0d read %02x, the Xe10 reads FF (KIT1-XE10-CG0-USERCG.TXT CGX 00%02x W20E=6A4B)",
                       a3, r, value, a3);
            errors = errors + 1;
          end
        end
      end
    end

    // Kit 2's rows (docs/probes/KIT2-XE10-CG2-USERCG.TXT, CGX for 0xA1 = 0x01..0x2F, both 0xA5
    // halves): the even page reads 0xFF in row 0x09 (:758 `CGX 2109 P20=2195 P00=6A0A W20E=6A4B
    // W20O=2195 W00E=6A4B W00O=6A0A`) and row 0x0C (:806 `CGX 210C P20=6A0A P00=6A0A W20E=6A4B`),
    // 0x8F in row 0x58 (:822 `CGX 0158 P20=6A0A P00=6A0A W20E=A0DD`, A0DD = 16 x 0x8F), and row
    // 0x09's odd page with bit 5 clear reads 0x00 (the same :758 `W00O=6A0A`, every 0xA1).
    for (ri = 0; ri < 3; ri = ri + 1) begin
      a3 = (ri == 0) ? 8'h09 : (ri == 1) ? 8'h0C : 8'h58;
      for (ai = 0; ai < 3; ai = ai + 1) begin
        a1 = (ai == 0) ? 8'h01 : (ai == 1) ? 8'h21 : 8'h2F;
        select_glyph(a1, a3);
        for (half = 0; half < 2; half = half + 1) begin
          write_io(8'hA5, half == 0 ? 8'h20 : 8'h00);
          for (r = 0; r < 16; r = r + 1) begin
            mem_read_byte(32'h000A_4000 + (r * 2), value);
            want = (a3 == 8'h58) ? 8'h8F : 8'hFF;
            if (value !== want) begin
              if (errors < 32)
                $display("FAIL: window even byte code A1=%02x A3=%02x A5=%02x row %0d read %02x, the Xe10 reads %02x (KIT2-XE10-CG2-USERCG.TXT CGX %02x%02x)",
                         a1, a3, half == 0 ? 8'h20 : 8'h00, r, value, want, a1, a3);
              errors = errors + 1;
            end
            if (a3 == 8'h09 && half == 1) begin
              mem_read_byte(32'h000A_4000 + (r * 2 + 1), value);
              if (value !== 8'h00) begin
                if (errors < 32)
                  $display("FAIL: window odd byte code A1=%02x A3=09 A5=00 row %0d read %02x, the Xe10 reads 00 (KIT2-XE10-CG2-USERCG.TXT CGX %02x09 W00O=6A0A)",
                           a1, r, value, a1);
                errors = errors + 1;
              end
            end
          end
        end
      end
    end

    // The user-CG class is not the font: code 0x1056 (A1 = 0x10, A3 = 0x56) is the CG RAM the
    // machine's battery-backed record lives in (KIT1-XE10-CG0-USERCG.TXT `CGW 1056`). A byte
    // written there through port 0xA9 reads back, where a font slot would answer the tag.
    write_io(8'hA1, 8'h10);
    write_io(8'hA3, 8'h56);
    write_io(8'hA5, 8'h20 | 8'h03);
    write_io(8'hA9, 8'hC3);
    read_io(8'hA9, value);
    if (value !== 8'hC3) begin
      $display("FAIL: user-CG code 0x1056 row 3 read %02x after writing C3: the column-0x20 rule reached the CG RAM class", value);
      errors = errors + 1;
    end
    // ...and its even window page stays the 0x8F dummy (KIT1-XE10-CG0-USERCG.TXT:518
    // `CGW 1056 00 8FFF8F02`, docs/probes/VRAM.TXT).
    mem_read_byte(32'h000A_4000 + 6, value);
    if (value !== 8'h8F) begin
      $display("FAIL: user-CG code 0x1056 even window byte read %02x, the Xe10 reads 8F", value);
      errors = errors + 1;
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_CG_TEN_LOW: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_CG_TEN_LOW: FAIL (%0d errors)", errors);
  end

  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_CG_TEN_LOW: TIMEOUT");
  end

endmodule

`default_nettype wire
