`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The character generator's read path: the four code classes NP2kai's cgrom_ia9 decides, driven through port 0xA9 and through the memory-mapped 0xA4000 window, with every byte the classes return coming from the machine's own FONT.ROM rows loaded into the read path's two sources here -- the ANK class from the pack's 8x16 slice, the JIS classes from the pack's FONT.ROM copy at pack_base + 0x80000 -- so the assertion is the dump's bytes (FONT.ROM[0x800+0x41*16], FONT.ROM[0x7C20], FONT.ROM[0xCC20]) and not a model of them. It does NOT drive the scanout (a text-plane cell holding a two-byte code still draws nothing) and it does not test the pack layout itself: it supplies the font region through the SDRAM's second port exactly as a real pack would. Plus the 20 configuration cells - the 14 software-DIP record bytes at CG store 0x810..0x81D and the six CPU/size cells - are a STATIC READ-ONLY VIEW of the OSD settings with a WRITE-THROUGH READ ECHO: a guest store through port 0xA9 or the 0xA4000 window commits NOTHING to the stored configuration, but the read echoes the byte the guest just wrote until the ITF's out 0xF0 re-POST (cfg_seed_reload) clears the echo, because the machine's own battery-backed record cells survive the ITF's stage-1A KANJI CG-RAM wipe (the Xa7C9W runtime capture holds the record intact at code 0x2056 rows 0..0xD, qemu-pc98 roms/pc98bios/memsw.inc) and the EMM386 fix's read fallback is structural. The record IMAGE is the OSD Machine field's own model table - Xe10 = the ITF's factory table BANK4@0x4924, Xe = bios/xe/BANK4.BIN@0x48E8 - and its SUM-CHECK byte is COMPUTED as row 0x81A = -(sum of rows 0x811..0x819) mod 256, so the ITF's marker/sum check (BANK4@0xFC677-0xFC6B5) passes for either model with the dumps' own 0x67/0x68. FAIL-FIRST: on the static-no-echo design the guest's write read back as the seed (the KANJI CG RAM ERROR defect), and on a constant-image design the Xe selection still answers the Xe10 rows.
//
// The character generator's read path: the four code classes NP2kai's cgrom_ia9 decides, driven through port 0xA9 and through the memory-mapped 0xA4000 window, with every byte the classes return coming from the machine's own FONT.ROM rows loaded into the read path's two sources here -- the ANK class from the pack's 8x16 slice, the JIS classes from the pack's FONT.ROM copy at pack_base + 0x80000 -- so the assertion is the dump's bytes (FONT.ROM[0x800+0x41*16], FONT.ROM[0x7C20], FONT.ROM[0xCC20]) and not a model of them. It does NOT drive the scanout (that is tb_pc9821_gdc_text's job) and it does not test the pack layout itself: it supplies the font region through the SDRAM's second port exactly as a real pack would. Plus the read-back splits: port 0xA9's ver0.78 test is the FULL low byte (io/cgrom.c:197), so low byte 0x89-0x8B takes the JIS branch with the half offset when two-byte (io/cgrom.c:208-217) or the ANK table when one-byte (:219-227); one-byte 0x09-0x0B returns 0x00 with NO fetch and no read stall (the slot NP2kai names is ZeroMemory'd, font/font.c:145-151); and the window's unused page is the machine's class-independent dummy 0x8F for every class (docs/probes/VRAM.TXT; NP2kai has one dummy page shared by all of them, io/cgrom.c:18,43-48). FAIL-FIRST: on the masked pre-fix class one-byte 0x09-0x0B returns the grid block's bytes and stalls the read for its burst, the half-set read of two-byte 0x418B answers 0 instead of the slot's right half, one-byte 0x89 reads the grid block instead of the ANK table, and the dummy pages answer 0x00 instead of 0x8F.

// The defect this bench exists for, and the shape of the fix.
//
// `cg_pattern` used to be `cg_gaiji ? cg_ram_q : cg_ank_valid ? cg_ank_byte :
// 8'h00` with `cg_ank_valid = !cg_two_byte && !cg_line[4]`. Every two-byte code that was not 0x56xx/0x57xx therefore
// read 0x00 -- every JIS kanji, and the class the five games use for EVERY
// character they draw: ZUN writes `codepoint & 0xFF` to 0xA1 and
// `(codepoint >> 8) - 0x20` to 0xA3 and reads 16 rows from 0xA9, so ASCII and
// kana arrive as 0x29xx/0x2Axx/0x2Bxx, i.e. NP2kai's "ver0.78" class
// (rec98/th01/hardware/grppsafx.cpp:24-64).
//
// The class table now reproduces NP2kai's cgrom_ia9 (io/cgrom.c:193-226) and
// cgwindowset (:17-58) -- the rule is to copy NP2kai rather than
// infer the chip -- with one deliberate divergence in the ADDRESSING: NP2kai's
// `(code & 0x7f7f) << 4` indexes its private BMP-derived 528 KiB font array, not
// the machine's FONT.ROM, so over a verbatim copy it reads the wrong glyph.
// The address used here is the dump's own,
// verified by rendering four glyphs:
//
//     32 bytes at 0x1800 + (ku - 0x21)*0xC00 + (ten - 0x20)*0x20
//
// with ku = code[6:0] + 0x20 and ten = code[14:8], the first 16 bytes the left
// half and the last 16 the right half.

`default_nettype none

module tb_pc9821_cg_read_path;
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
  // The port 0xA9 read wait and a sticky font-request flag: the one-byte 0x09-0x0B
  // class must fetch NOTHING and stall NOTHING (NP2kai answers its zeroed slot with no
  // transaction at all, io/cgrom.c:198-207 + font/font.c:145-151).
  wire cg_rd_hold;
  reg  font_req_seen = 1'b0;
  always @(posedge clk_sys) if (font_req) font_req_seen <= 1'b1;
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
  // The machine's own glyph rows. These are the whole assertion: a read at the
  // wrong address cannot produce them, and each vector was taken from
  // bios/xe10/FONT.ROM and rendered before it was trusted.
  localparam [31:0] FONT_PACK_OFFSET = 32'h0008_0000;
  // FONT.ROM[0x800 + 0x41*16 .. +16): the 8x16 ANK 'A' table entry, which the
  // core's pack already carries as its 4 KiB ANK slice.
  localparam [127:0] ANK_A = 128'h000000081422414141417f4141410000;
  // FONT.ROM[0x890 .. +16): the 8x16 ANK table entry for CODE 0x89, the class
  // NP2kai sends one-byte codes 0x89-0x8B to (io/cgrom.c:219-227 reads
  // 0x80000 + code<<4 there): the unmasked ver0.78 test leaves them for the ANK
  // arm, where the masked test read the grid block's nonsense address instead.
  localparam [127:0] ANK_89 = 128'h4444447c444444001f04040404040400;
  // FONT.ROM[0x7C20 .. +32): JIS ku 0x29 ten 0x41, the row ZUN fetches as
  // code 0x4109 -- 'A' in the left half, an empty right half. b256(v, i) is
  // dump byte i: the FIRST 16 bytes of the record are FONT.ROM[0x7C20..0x7C2F]
  // (the left half), the last 16 FONT.ROM[0x7C30..0x7C3F] (the right).
  localparam [255:0] JIS_A =
      256'h00181824242424243c42424242420000_00000000000000000000000000000000;
  // FONT.ROM[0xCC20 .. +32): JIS ku 0x30 ten 0x21, a real kanji fetched as
  // code 0x2110, with both halves populated.
  localparam [255:0] KANJI =
      256'h003f0202023f22222222223f0202027f_00fe202020fe2222222222fe202020ff;
  // A TAGGED glyph at FONT.ROM[0x9420 .. +32), the grid slot of the masked code
  // 0x410B (ku 0x2B ten 0x41): left row r reads 0x90+r and right row r 0x60+r,
  // so a returned byte names the half AND the row it came from whatever the class
  // table sent there. The half SELECTOR below is the sourced claim (NP2kai
  // io/cgrom.c:208-217 sends low byte 0x89-0x8B to the JIS branch with the half
  // offset); the bytes are test data served through the machine's own grid
  // mapping, because the real row 0x2B glyphs are half-width and their right
  // halves are zero - byte-indistinguishable from the bug this pins.
  localparam [255:0] JIS_HALF =
      256'h909192939495969798999A9B9C9D9E9F_606162636465666768696A6B6C6D6E6F;

  function automatic [7:0] b128(input [127:0] v, input integer i);
    b128 = v[(15 - i) * 8 +: 8];
  endfunction
  function automatic [7:0] b256(input [255:0] v, input integer i);
    b256 = v[(31 - i) * 8 +: 8];
  endfunction

  // Every byte the font region answers. The three vectors are the machine's;
  // anything else gets a value derived from the offset, so a fetch at the wrong
  // address is visible rather than plausible.
  function automatic [7:0] font_byte(input [18:0] off);
    begin
      if (off >= 19'h0C10 && off < 19'h0C20)
        font_byte = b128(ANK_A, off - 19'h0C10);
      else if (off >= 19'h0890 && off < 19'h08A0)
        font_byte = b128(ANK_89, off - 19'h0890);
      else if (off >= 19'h7C20 && off < 19'h7C40)
        font_byte = b256(JIS_A, off - 19'h7C20);
      else if (off >= 19'h9420 && off < 19'h9440)
        font_byte = b256(JIS_HALF, off - 19'h9420);
      else if (off >= 19'hCC20 && off < 19'hCC40)
        font_byte = b256(KANJI, off - 19'hCC20);
      else
        font_byte = off[7:0] ^ 8'h5A;
    end
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

  pc9821_memory_subsystem dut_mem (
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
  integer i, r;
  reg [7:0] value;
  reg [7:0] want;

  // The 14 software-DIP record bytes, store 0x810..0x81D, byte 0 first. Sourced from
  // the ITF's own factory table (BANK4@0x4924 carries the ten sum-checked bytes
  // C1 8C 81 CD FF 00 00 AA 55 67) plus the record's first/marker/tail bytes; the same
  // Xe10-model image pc9821_cg.sv's CG_RECORD_INIT seeds at power-up (the Xe model's
  // rows are section 0d's).
  localparam [7:0] RECORD_BYTES [0:13] = '{8'h04, 8'hC1, 8'h8C, 8'h81, 8'hCD, 8'hFF,
                                           8'h00, 8'h00, 8'hAA, 8'h55, 8'h67, 8'h86,
                                           8'h8A, 8'hFF};

  // ==== STIMULUS ====

  task automatic fail(input [8*96-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

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

  task automatic read_io(input [7:0] portnum, output [7:0] data);
    begin
      @(negedge clk_sys);
      io_addr = portnum;
      #1 data = io_dout;
      @(negedge clk_sys);
    end
  endtask

  // Read one byte through the memory port at the window's address.
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

  // Write one byte through the memory port at the window's address - the path the
  // ITF's own stage-1A wipe takes (`stosb` at ES = 0xA400, odd offsets).
  task automatic mem_write_byte(input [31:0] addr, input [7:0] data);
    integer lane;
    begin
      lane = addr[1:0];
      @(negedge clk_sys);
      cpu_addr = addr; cpu_be = 4'h01 << lane; cpu_valid = 1; cpu_write = 1;
      cpu_din = {24'd0, data} << (lane * 8);
      cpu_line_read = 0;
      // The window responder completes a write with cpu_ready and no resp (S_WRITE ->
      // S_HOLD), so the write's handshake is ready-only.
      while (!cpu_ready) @(negedge clk_sys);
      @(negedge clk_sys); cpu_valid = 0; cpu_write = 0;
      repeat (4) @(negedge clk_sys);
    end
  endtask

  // Select a glyph and let the fetch for its block run to completion. The fetch
  // is driven by the code's block address, so it starts within a couple of
  // cycles of the 0xA3 write; waiting on the GDC's own request line is what
  // makes the reads below deterministic rather than a race with the backend.
  task automatic select_glyph(input [7:0] hi, input [7:0] lo);
    begin
      write_io(8'hA1, hi);
      write_io(8'hA3, lo);
      repeat (4) @(negedge clk_sys);
      while (font_req) @(negedge clk_sys);
      repeat (4) @(negedge clk_sys);
    end
  endtask

  // ==== CHECKS ====

  // Read one configuration-image cell back through the port the ITF itself uses: the code
  // triple selects {code[14:8], code[0], cg_lr, row} and 0xA9 returns the byte there.
  task automatic read_cell(input [7:0] hi, input [7:0] lo, input [7:0] a5, output [7:0] data);
    begin
      write_io(8'hA1, hi);
      write_io(8'hA3, lo);
      write_io(8'hA5, a5);
      read_io(8'hA9, data);
    end
  endtask

  // The configuration image the ITF reads to decide the machine's CPU mode and its
  // extended-memory size, at the six cells its own decoder names. A 32 MiB machine:
  //   0x1C67 = 0xF0 ((high nibble)+1 saturates at 16 MiB)
  //   0x1C6D = 0x78 (the escape, because (32-1)<<3 would collide with the marker)
  //   0x1C6E/0x1C6F = 16, the escape's 16-bit little-endian value, so 16 + 16 = 32 MiB
  task automatic check_config_image;
    begin
      read_cell(8'h12, 8'h56, 8'h07, value);
      if (value !== 8'h01) fail("the mode cell 0x497 is not the firmware's own marker 0x01");
      read_cell(8'h72, 8'h57, 8'h27, value);
      if (value !== 8'h28) fail("the image-present cell 0x1CA7 is not the firmware's 0x28");
      read_cell(8'h71, 8'h57, 8'h27, value);
      if (value !== 8'hF0) fail("the size cell 0x1C67 does not encode a 32 MiB machine");
      read_cell(8'h71, 8'h57, 8'h2D, value);
      if (value !== 8'h78) fail("the size cell 0x1C6D is not the escape marker 0x78");
      read_cell(8'h71, 8'h57, 8'h2E, value);
      if (value !== 8'h10) fail("the escape low byte is not 32-16 = 16 MiB");
      read_cell(8'h71, 8'h57, 8'h2F, value);
      if (value !== 8'h00) fail("the escape high byte is not 0");
      // The record at 0x810-0x81D is the OTHER seed and must be untouched: cell 0x810 is its
      // first byte, 0x04 (pc9821_gdc_text's CG_RECORD_BYTES).
      read_cell(8'h20, 8'h56, 8'h00, value);
      if (value !== 8'h04) fail("the configuration seed overwrote the DIP record at 0x810");
    end
  endtask

  // Select a record cell (code 0x2056, cg_lr = 1): A1 = 0x20, A3 = 0x56, A5 = row with
  // bit 5 CLEAR (cg_lr = 1). Store address is {0x20, 0, 1, row} = 0x810 + row.
  task automatic read_record(input [3:0] row, output [7:0] data);
    read_cell(8'h20, 8'h56, row, data);
  endtask

  task automatic write_record(input [3:0] row, input [7:0] data);
    begin
      write_io(8'hA1, 8'h20);
      write_io(8'hA3, 8'h56);
      write_io(8'hA5, row);
      write_io(8'hA9, data);
    end
  endtask

  initial begin
    repeat (3) @(posedge clk_sys);
    @(negedge clk_sys);
    reset = 0;

    // Release the CPU and put the machine's 8x16 ANK 'A' into the pack's 4 KiB
    // slice, where the pack builder takes it from (FONT.ROM[0x800..0x1800] at
    // pack offset 0x30000). Word i of the slice holds bytes 2i and 2i+1. Code
    // 0x89's entry (FONT.ROM[0x890]) rides along: it is the ANK class NP2kai
    // answers for one-byte codes 0x89-0x8B (io/cgrom.c:219-227).
    ioctl_download = 1;
    for (i = 0; i < 8; i = i + 1)
      send_word(27'h0003_0410 + i[26:0] * 2,
                {b128(ANK_A, i*2 + 1), b128(ANK_A, i*2)});
    for (i = 0; i < 8; i = i + 1)
      send_word(27'h0003_0890 + i[26:0] * 2,
                {b128(ANK_89, i*2 + 1), b128(ANK_89, i*2)});
    send_word(27'd0, 16'hBEEF);
    repeat (2) @(posedge clk_sys);
    ioctl_download = 0;
    repeat (3) @(posedge clk_sys);
    if (!cpu_run) fail("cpu_run never asserted after the pack download");

    // ---------------------------------------------------------------
    // 0. the configuration image: the seed walk runs on the rst_n_sys release, which this
    //    bench has already taken, so the six cells are in the store before the pack is up.
    // ---------------------------------------------------------------
    check_config_image;

    // ---------------------------------------------------------------
    // 0b. the seeded cells are a STATIC READ-ONLY VIEW with a WRITE-THROUGH READ ECHO.
    // A guest
    //     store to a seeded cell commits NOTHING to the stored configuration, but the READ
    //     echoes the byte the guest just wrote for the rest of this pass - the KANJI CG-RAM
    //     test's own write-then-read must match - while an unwritten cell keeps the
    //     machine's image, and the ITF's CPU-mode reset (cfg_seed_reload) re-establishes
    //     the image at the next POST pass. FAIL-FIRST: on the static-no-echo design the
    //     guest's 0xFF read back as the seed 0xF0 (the KANJI CG RAM ERROR defect).
    // ---------------------------------------------------------------
    select_glyph(8'h71, 8'h57);
    write_io(8'hA5, 8'h27);
    write_io(8'hA9, 8'hFF);
    read_io(8'hA9, value);
    if (value !== 8'hFF) fail("the seed shadowed the guest's own write to cell 0x1C67");
    read_cell(8'h72, 8'h57, 8'h27, value);
    if (value !== 8'h28) fail("the write to 0x1C67 also moved the unwritten cell 0x1CA7");
    cfg_seed_reload = 1'b1;
    @(negedge clk_sys);
    cfg_seed_reload = 1'b0;
    @(negedge clk_sys);
    read_cell(8'h71, 8'h57, 8'h27, value);
    if (value !== 8'hF0) fail("cfg_seed_reload did not re-establish the seed at 0x1C67");
    read_cell(8'h71, 8'h57, 8'h2D, value);
    if (value !== 8'h78) fail("cfg_seed_reload disturbed the size cell 0x1C6D");

    // ---------------------------------------------------------------
    // 0c. the record cells echo the wipe too (answer-cell-059A-REPORT.md + lane
    //     kanji-test-writethrough). The stage-1A KANJI CG-RAM test writes 0xFF then 0x00
    //     over the whole store - including the 14 record cells 0x810..0x81D - and never
    //     restores them; the ITF then re-POSTs (`out 0xF0` = cfg_seed_reload) and re-runs
    //     the drive probe at BANK4@0x1BB6, which reads record byte 5 (0x815) and stores
    //     table[nibble]*600 into [0:59A]. During the wipe the read echoes the write; after
    //     the re-POST the static image returns, so 0x815 = 0xFF -> [0:59A] = 0 exactly as
    //     on the machine (the stored configuration was never overwritten).
    // ---------------------------------------------------------------
    for (r = 0; r < 14; r = r + 1) write_record(r[3:0], 8'h00);
    read_record(4'd5, value);
    if (value !== 8'h00) fail("the KANJI wipe write to record byte 5 (0x815) was not readable back");
    cfg_seed_reload = 1'b1;
    @(negedge clk_sys);
    cfg_seed_reload = 1'b0;
    @(negedge clk_sys);
    read_record(4'd5, value);
    if (value !== 8'hFF) fail("cfg_seed_reload did not re-answer record byte 5 (0x815) with 0xFF");
    for (r = 0; r < 14; r = r + 1) begin
      read_record(r[3:0], value);
      if (value !== RECORD_BYTES[r]) begin
        $display("FAIL: cfg_seed_reload re-answered record cell %0d as %02x, seeded %02x",
                 r, value, RECORD_BYTES[r]);
        errors = errors + 1;
      end
    end
    // The same wipe through the 0xA4000 window (the path the KANJI test itself uses):
    // window offset 0x01 is record row 0 (store 0x810, image 0x04). Write 0xFF, the read
    // must echo 0xFF, then cfg_seed_reload must bring back the image byte 0x04.
    mem_write_byte(32'h000A_4001, 8'hFF);
    mem_read_byte(32'h000A_4001, value);
    if (value !== 8'hFF) fail("the window wipe of record row 0 was not echoed (write-through)");
    cfg_seed_reload = 1'b1;
    @(negedge clk_sys);
    cfg_seed_reload = 1'b0;
    @(negedge clk_sys);
    mem_read_byte(32'h000A_4001, value);
    if (value !== 8'h04) fail("cfg_seed_reload did not re-answer record row 0 with its image 0x04");

    // ---------------------------------------------------------------
    // 1. the one-byte ANK class, port 0xA9, every row
    //    code 0x0041, and the ANK read is gated by 0xA5 bit 4.
    // ---------------------------------------------------------------
    select_glyph(8'h00, 8'h41);
    for (r = 0; r < 16; r = r + 1) begin
      write_io(8'hA5, r[7:0]);
      read_io(8'hA9, value);
      want = b128(ANK_A, r);
      if (value !== want) begin
        $display("FAIL: ANK code 0x0041 row %0d read %02x, FONT.ROM[0x800+0x41*16+%0d] is %02x",
                 r, value, r, want);
        errors = errors + 1;
      end
    end
    write_io(8'hA5, 8'h10);
    read_io(8'hA9, value);
    if (value !== 8'h00)
      fail("ANK read with 0xA5 bit 4 set was not blank");

    // ---------------------------------------------------------------
    // 2. ver0.78 (0xA3 in 0x09..0x0B, half clear): the class the games use for
    //    every character. code 0x4109, glyph FONT.ROM[0x7C20].
    // ---------------------------------------------------------------
    select_glyph(8'h41, 8'h09);
    for (r = 0; r < 16; r = r + 1) begin
      write_io(8'hA5, 8'h20 | r[7:0]);   // bit 5 set -> half clear
      read_io(8'hA9, value);
      want = b256(JIS_A, r);
      if (value !== want) begin
        $display("FAIL: ver0.78 code 0x4109 row %0d read %02x, FONT.ROM[0x7C20+%0d] is %02x",
                 r, value, r, want);
        errors = errors + 1;
      end
    end
    // with the half set the class reads back 0 (cgrom_ia9 falls out of the
    // branch with no return)
    write_io(8'hA5, 8'h03);
    read_io(8'hA9, value);
    if (value !== 8'h00)
      fail("ver0.78 with the half set did not read back 0");

    // ---------------------------------------------------------------
    // 3. a real kanji, code 0x2110, halves from 0xA5 bit 5.
    //    glyph FONT.ROM[0xCC20].
    // ---------------------------------------------------------------
    select_glyph(8'h21, 8'h10);
    for (r = 0; r < 16; r = r + 1) begin
      write_io(8'hA5, 8'h20 | r[7:0]);   // left half
      read_io(8'hA9, value);
      want = b256(KANJI, r);
      if (value !== want) begin
        $display("FAIL: kanji code 0x2110 left row %0d read %02x, FONT.ROM[0xCC20+%0d] is %02x",
                 r, value, r, want);
        errors = errors + 1;
      end
      write_io(8'hA5, r[7:0]);           // bit 5 clear -> right half
      read_io(8'hA9, value);
      want = b256(KANJI, 16 + r);
      if (value !== want) begin
        $display("FAIL: kanji code 0x2110 right row %0d read %02x, FONT.ROM[0xCC20+%0d] is %02x",
                 r, value, 16 + r, want);
        errors = errors + 1;
      end
    end

    // ---------------------------------------------------------------
    // 4. the user-CG class still round-trips through port 0xA9, and a one-byte
    //    code 0x56 is the ANK class, not the store.
    // ---------------------------------------------------------------
    select_glyph(8'h10, 8'h56);
    write_io(8'hA5, 8'h03);
    write_io(8'hA9, 8'h5A);
    read_io(8'hA9, value);
    if (value !== 8'h5A) fail("user CG write/read through port 0xA9");
    select_glyph(8'h00, 8'h56);
    write_io(8'hA5, 8'h00);
    read_io(8'hA9, value);
    if (value === 8'h5A) fail("a one-byte code 0x0056 read back user CG data");

    // ---------------------------------------------------------------
    // 5. the same classes through the memory-mapped window, which is the other
    //    CPU-side view: {page, row} = {offset[0], offset[4:1]}, and the class
    //    decides which page carries the glyph. A window read is a 4-byte
    //    transfer, so each offset is read on its own.
    // ---------------------------------------------------------------
    // ANK: the odd (high) page is the glyph, the even page is the dummy.
    select_glyph(8'h00, 8'h41);
    for (r = 0; r < 16; r = r + 1) begin
      mem_read_byte(32'h000A_4000 + (r * 2 + 1), value);
      want = b128(ANK_A, r);
      if (value !== want) begin
        $display("FAIL: window ANK row %0d read %02x, the glyph byte is %02x",
                 r, value, want);
        errors = errors + 1;
      end
      mem_read_byte(32'h000A_4000 + (r * 2), value);
      if (value !== 8'h8F)
        fail("window ANK low page is not the machine's class-independent dummy 0x8F");
    end

    // ver0.78: the odd page is the glyph, the even page the dummy. The half
    // select must be driven here (0xA5 bit 5 SET -> the left half, cgrom.c:199):
    // with the half clear the whole ver0.78 window goes to the dummy.
    select_glyph(8'h41, 8'h09);
    for (r = 0; r < 16; r = r + 1) begin
      write_io(8'hA5, 8'h20 | r[4:0]);
      mem_read_byte(32'h000A_4000 + (r * 2 + 1), value);
      want = b256(JIS_A, r);
      if (value !== want) begin
        $display("FAIL: window ver0.78 row %0d read %02x, FONT.ROM[0x7C20+%0d] is %02x",
                 r, value, r, want);
        errors = errors + 1;
      end
      mem_read_byte(32'h000A_4000 + (r * 2), value);
      if (value !== 8'h8F)
        fail("window ver0.78 low page is not the machine's class-independent dummy 0x8F");
    end

    // kanji: the even page is the left half and the odd page the right half.
    select_glyph(8'h21, 8'h10);
    for (r = 0; r < 16; r = r + 1) begin
      mem_read_byte(32'h000A_4000 + (r * 2), value);
      want = b256(KANJI, r);
      if (value !== want) begin
        $display("FAIL: window kanji left row %0d read %02x, FONT.ROM[0xCC20+%0d] is %02x",
                 r, value, r, want);
        errors = errors + 1;
      end
      mem_read_byte(32'h000A_4000 + (r * 2 + 1), value);
      want = b256(KANJI, 16 + r);
      if (value !== want) begin
        $display("FAIL: window kanji right row %0d read %02x, FONT.ROM[0xCC20+%0d] is %02x",
                 r, value, 16 + r, want);
        errors = errors + 1;
      end
    end

    // The window and port 0xA9 must agree about the same glyph byte.
    select_glyph(8'h41, 8'h09);
    write_io(8'hA5, 8'h20 | 8'h05);
    read_io(8'hA9, value);
    want = b256(JIS_A, 5);
    mem_read_byte(32'h000A_4000 + 11, value);
    if (value !== want)
      fail("the window and port 0xA9 disagree about the same glyph byte");

    // ---------------------------------------------------------------
    // 6. the port-0xA9 ver0.78 class mask is the FULL low byte:
    //    NP2kai's cgrom_ia9 tests `type = cr->code & 0x00ff` (io/cgrom.c:197), so
    //    low byte 0x89-0x8B is NOT ver0.78 there and a two-byte code falls to the
    //    JIS branch WITH the half offset (:208-217): the half clear reads the
    //    masked code's slot LEFT 16 bytes, the half set its RIGHT 16. The masked
    //    class answered 0 for the half set (the ver0.78 fall-through, :198-207),
    //    which is not this code's branch at all.
    // ---------------------------------------------------------------
    select_glyph(8'h41, 8'h8B);
    for (r = 0; r < 16; r = r + 1) begin
      write_io(8'hA5, 8'h20 | r[7:0]);   // bit 5 set -> half clear -> left
      read_io(8'hA9, value);
      want = b256(JIS_HALF, r);
      if (value !== want) begin
        $display("FAIL: code 0x418B left row %0d read %02x, the slot's left byte is %02x",
                 r, value, want);
        errors = errors + 1;
      end
      write_io(8'hA5, r[7:0]);           // bit 5 clear -> half set -> right
      read_io(8'hA9, value);
      want = b256(JIS_HALF, 16 + r);
      if (value !== want) begin
        $display("FAIL: code 0x418B right row %0d read %02x, the slot's right byte is %02x",
                 r, value, want);
        errors = errors + 1;
      end
    end
    // ... while a REAL ver0.78 code (low byte 0x0B) keeps the fall-through: the
    // half set reads 0 and the half clear reads the slot's LEFT half
    // (io/cgrom.c:198-205) - the class ZUN's games actually draw with.
    select_glyph(8'h41, 8'h0B);
    write_io(8'hA5, 8'h03);
    read_io(8'hA9, value);
    if (value !== 8'h00)
      fail("ver0.78 code 0x410B with the half set read non-zero");
    write_io(8'hA5, 8'h23);
    read_io(8'hA9, value);
    want = b256(JIS_HALF, 3);
    if (value !== want)
      fail("ver0.78 code 0x410B with the half clear did not read the slot's left half");

    // ---------------------------------------------------------------
    // 7. one-byte 0x09-0x0B reads 0x00 and fetches nothing.
    //    The ver0.78 branch names fontrom[0x90 + row], which font_load's
    //    ZeroMemory passes and no loader writes (font/font.c:145-151), and with
    //    the half set it falls out with no return (cgrom.c:198-207): 0 either way.
    //    The old class fetched the two-byte grid block at the nonsense address
    //    cg_jis_addr(0, lo) and STALLED the read for its burst - both the data and
    //    the wait state diverge. The grid slot at that address holds real dump
    //    bytes here (font_byte's default pattern), so a non-zero read fails.
    // ---------------------------------------------------------------
    font_req_seen = 1'b0;
    write_io(8'hA1, 8'h00);
    write_io(8'hA3, 8'h0A);
    if (cg_rd_hold !== 1'b0)
      fail("one-byte 0x0A stalled port 0xA9: NP2kai's read is immediate");
    repeat (40) @(negedge clk_sys);
    if (font_req_seen)
      fail("one-byte 0x0A fetched a font block: NP2kai answers 0 from its zeroed slot");
    if (cg_rd_hold !== 1'b0)
      fail("one-byte 0x0A stalled port 0xA9: NP2kai's read is immediate");
    for (r = 0; r < 16; r = r + 1) begin
      write_io(8'hA5, 8'h20 | r[7:0]);   // half clear
      read_io(8'hA9, value);
      if (value !== 8'h00) begin
        $display("FAIL: one-byte 0x0A row %0d (half clear) read %02x, NP2kai returns 0x00",
                 r, value);
        errors = errors + 1;
      end
      write_io(8'hA5, r[7:0]);           // half set
      read_io(8'hA9, value);
      if (value !== 8'h00) begin
        $display("FAIL: one-byte 0x0A row %0d (half set) read %02x, NP2kai returns 0x00",
                 r, value);
        errors = errors + 1;
      end
    end
    write_io(8'hA3, 8'h0B);
    write_io(8'hA5, 8'h20);
    read_io(8'hA9, value);
    if (value !== 8'h00)
      fail("one-byte 0x0B read non-zero");

    // ---------------------------------------------------------------
    // 8. one-byte 0x89-0x8B is the ANK class on the port:
    //    past the unmasked ver0.78 test they take the one-byte branch, which
    //    reads the ANK table at 0x80000 + code<<4 (io/cgrom.c:219-227) - the
    //    machine's own FONT.ROM[0x890] bytes for code 0x89 - gated blank by
    //    0xA5 bit 4. The masked class sent them to the grid block instead.
    // ---------------------------------------------------------------
    font_req_seen = 1'b0;
    write_io(8'hA1, 8'h00);
    write_io(8'hA3, 8'h89);
    if (cg_rd_hold !== 1'b0)
      fail("one-byte 0x89 stalled port 0xA9: the ANK table answers immediately");
    repeat (40) @(negedge clk_sys);
    if (font_req_seen)
      fail("one-byte 0x89 fetched a font block: it is the ANK class");
    if (cg_rd_hold !== 1'b0)
      fail("one-byte 0x89 stalled port 0xA9: the ANK table answers immediately");
    for (r = 0; r < 16; r = r + 1) begin
      write_io(8'hA5, r[7:0]);
      read_io(8'hA9, value);
      want = b128(ANK_89, r);
      if (value !== want) begin
        $display("FAIL: one-byte 0x89 row %0d read %02x, FONT.ROM[0x890+%0d] is %02x",
                 r, value, r, want);
        errors = errors + 1;
      end
    end
    write_io(8'hA5, 8'h10);              // 0xA5 bit 4 blanks the ANK read
    read_io(8'hA9, value);
    if (value !== 8'h00)
      fail("ANK read for code 0x89 with 0xA5 bit 4 set was not blank");

    // ---------------------------------------------------------------
    // 0d. the record IMAGE is the OSD Machine field's own model table with the
    //     SUM-CHECK BYTE COMPUTED: row A = -(sum of rows 1..9)
    //     mod 256, so the ITF's marker/sum check (BANK4@0xFC677-0xFC6B5) passes for
    //     either model with the DUMPS' own bytes - 0x67 at the Xe10 table
    //     (BANK4@0x4924) and 0x68 at the Xe's (bios/xe/BANK4.BIN@0x48E8). The field
    //     is sampled at machine reset only, like every DIP value. FAIL-FIRST: with
    //     the record a constant image the Xe selection still answers the Xe10 rows.
    // ---------------------------------------------------------------
    begin
      integer sum, rr;
      // The Xe10 default: the dump's own ten bytes, marker included, summing to 0.
      sum = 0;
      for (rr = 1; rr <= 10; rr = rr + 1) begin
        read_record(rr[3:0], value);
        sum = sum + value;
      end
      if (sum[7:0] !== 8'h00) begin
        $display("FAIL: the Xe10 record's ten bytes sum to %04x, want 0 mod 256 (BANK4@0xFC689)", sum);
        errors = errors + 1;
      end
      read_record(4'd10, value);
      if (value !== 8'h67)
        fail("the Xe10 record's COMPUTED sum-check byte is not 0x67 (BANK4@0x4924's own byte)");
      read_record(4'd8, value);
      if (value !== 8'hAA) fail("the record's marker high byte moved off 0xAA");

      // A MID-RUN MACHINE FLIP MOVES NOTHING (reset-only application).
      bios_set = 4'd1;
      repeat (2) @(posedge clk_sys);
      read_record(4'd3, value);
      if (value !== 8'h81) fail("a mid-run Machine flip moved the record under the running guest");
      read_record(4'd10, value);
      if (value !== 8'h67) fail("a mid-run Machine flip moved the record's checksum byte");

      // ... and the next machine reset applies the XE's own table: rows 3/0xC = 80/82
      // (bios/xe/BANK4.BIN@0x48E8's factory image and its 0x4858 code store) with the
      // checksum still COMPUTED - 0x68 there, which is the dump's own byte too.
      reset = 1;
      repeat (3) @(posedge clk_sys);
      @(negedge clk_sys);
      reset = 0;
      repeat (2) @(posedge clk_sys);
      read_record(4'd3, value);
      if (value !== 8'h80) fail("the Xe record's row 3 is not the Xe ITF table's 0x80");
      read_record(4'd12, value);
      if (value !== 8'h82) fail("the Xe record's row 0xC is not the Xe dump's 0x82");
      read_record(4'd10, value);
      if (value !== 8'h68)
        fail("the Xe record's COMPUTED sum-check byte is not 0x68 (the Xe dump's own byte)");
      read_record(4'd8, value);
      if (value !== 8'hAA) fail("the Xe record lost the AA55 marker (rows 8/9 are model-independent)");
      sum = 0;
      for (rr = 1; rr <= 10; rr = rr + 1) begin
        read_record(rr[3:0], value);
        sum = sum + value;
      end
      if (sum[7:0] !== 8'h00) begin
        $display("FAIL: the Xe record's ten bytes sum to %04x, want 0 mod 256", sum);
        errors = errors + 1;
      end
    end

  // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_CG_READ_PATH: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_CG_READ_PATH: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_CG_READ_PATH: TIMEOUT");
  end

endmodule

`default_nettype wire
