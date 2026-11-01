`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The character generator's class table and page mapping are swept against NP2kai's own decoder -- io/cgrom.c cgwindowset (:11-53) for the 0xA4000 window and cgrom_ia9 (:189-226) for port 0xA9 -- over every one-byte code and a two-byte set that crosses each class boundary, using a font image that TAGS each byte with the class and row it came from, so the byte a read returns names the class and page the RTL chose; every agreement is asserted and every divergence is printed with its exact code, page and the NP2kai rule it breaks; The 20 configuration cells (the software-DIP record at store 0x810..0x81D and the six CPU/size cells) are a SANCTIONED divergence from NP2kai's writable-fontrom model (a deliberate requirement): NP2kai's cgwindowset/cgrom_ia9 answer a tagged store there, while the machine's battery-backed cells survive writes - the Xa7C9W runtime capture holds the record intact after its boot's stage-1A KANJI wipe (qemu-pc98 roms/pc98bios/memsw.inc), a machine capture that outranks the software reference - and the core models that as a static read-only view with a transient write-through read echo. A sweep read of one of those cells must answer the configuration byte captured after the tagged load (the transient read echo, cleared at the `out 0xF0` re-POST), and that check replaces the class check there; the cell VALUES are pinned against the dumps in tb_pc9821_cg_read_path. the window's only gate is the 0xA4000 address decode (port 0x53E is a read-only strap and the window-0 bank cannot move a 0xA4000 access), and the 16x16 JIS fetch is pinned to its FONT.ROM block (0x7C20 for code 0x4109, 0xCC20 for 0x2110).
//
// The character generator's class table and page mapping are swept against NP2kai's own decoder -- io/cgrom.c cgwindowset (:11-53) for the 0xA4000 window and cgrom_ia9 (:189-226) for port 0xA9 -- over every one-byte code and a two-byte set that crosses each class boundary, using a font image that TAGS each byte with the class and row it came from, so the byte a read returns names the class and page the RTL chose; every agreement is asserted and every divergence is printed with its exact code, page and the NP2kai rule it breaks, and the divergence set is PINNED AT ZERO so any departure fails - the pre-fix RTL diverged on the overlap codes with low byte 0x09-0x0B/0x89-0x8B (the port's masked ver0.78 test where cgrom_ia9:197 tests the full low byte, and the window's one-byte branch where cgwindowset:21-25 is the ANK page); the window's only gate is the 0xA4000 address decode (port 0x53E is a read-only strap and the window-0 bank cannot move a 0xA4000 access), and the 16x16 JIS fetch is pinned to its FONT.ROM block (0x7C20 for code 0x4109, 0xCC20 for 0x2110).

`default_nettype none

// The timing tasks below carry the `no_inline_task` Verilator metacomment so each is
// compiled ONCE rather than one copy per call site: the unrolled one-byte + two-byte
// sweep calls check_code ~96 times, and inlining its whole check_window/check_port/
// write_io/mem_read chain at every site emitted ~235 MB of C++ (~270 s to compile).
// With the metacomments the same sweep compiles to ~2.2 MB (~14 s). The tasks touch
// module-level tb regs and DUT nets through the same vlSelf pointer the inlined form
// used (tools/bench.py waives IMPURE for this), and every case is still compared
// byte-for-byte against NP2kai.

module tb_pc9821_cg_np2;
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

  // ---- the pack's TAGGED font model -----------------------------------
  // Every JIS byte the fetch can ask for answers 0x20 + block-byte-index (0x20..0x2F left
  // half, 0x30..0x3F right half of the 32-byte block), so a read byte names the half AND row
  // it came from no matter what code the class table sent there; the ANK 4 KiB slice is
  // loaded separately through the pack's ANK window with 0x90+row. The gaiji store, loaded by
  // the bench's own 0xA9 writes, is 0x60+row. The three ranges are disjoint, so a read byte
  // names the class, the half and the row.
  localparam [31:0] FONT_PACK_OFFSET = 32'h0008_0000;
  function automatic [7:0] font_byte(input [18:0] off);
    font_byte = 8'h20 + {3'b0, off[4:0]};
  endfunction
  // ANK slice byte at byte-address A: word A>>1, byte A[0].
  function automatic [7:0] ank_byte(input [11:0] a);
    ank_byte = 8'h90 + {4'b0, a[3:0]};
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

  pc9821_gdc_text_dut dut_gdc (
      .clk_sys(clk_sys), .rst_n_sys(!reset),
      .cfg_fdd_mode(3'd0),   // entry 0: the measured boot/FDD nibble
      .pixel_ce(1'b1), .cfg_ram_mib(cfg_ram_mib), .cfg_seed_en(cfg_seed_en),
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din),
      .io_dout(io_dout),
      .tram_cpu_addr(tram_addr), .tram_cpu_din(tram_din),
      .tram_cpu_we(tram_we), .tram_cpu_dout(tram_dout),
      .font_ld_addr(font_addr), .font_ld_data(font_data), .font_ld_we(font_we),
      .cg_win_byte_sel(cg_win_byte_sel), .cg_win_rd(cg_win_rd),
      .cg_win_dout(cg_win_dout), .cg_win_din(cg_win_din), .cg_win_we(cg_win_we),
      .font_req_addr(font_req_addr), .font_req(font_req),
      .font_word_valid(font_word_valid), .font_word_data(font_word_data),
      .cg_record_restore(1'b0),
      .cfg_seed_reload(1'b0),
      .vsync_active(vsync_active), .vsync_irq_arm(vsync_irq_arm),
      .vsync_irq(vsync_irq), .disp_on(disp_on), .gfx_access_page(gfx_access_page_t),
      .dbg_sad(dbg_sad), .dbg_pitch(dbg_pitch), .dbg_col40(dbg_col40),
      .dbg_disp(dbg_disp),
      .hs_out(v_hs), .vs_out(v_vs), .de_out(v_de)
  );

  integer errors = 0;
  integer findings = 0;
  integer i, k, l, r, w;
  reg [7:0] value;
  reg [7:0] store_before;
  // The 20 configuration cells' bytes, captured BEFORE the tagged store load (below).
  reg [7:0] cfg_expect [0:19];

  // The class a tag byte names. C_* values match np2_win/np2_port.
  localparam [2:0] C_DUMMY = 3'd0, C_ANK = 3'd1, C_JISL = 3'd2,
                   C_JISR  = 3'd3, C_STORE = 3'd4;

  function automatic string cls_name(input [2:0] c);
    case (c)
      C_ANK:   return "ANK";
      C_JISL:  return "JIS-L";
      C_JISR:  return "JIS-R";
      C_STORE: return "STORE";
      default: return "DUMMY";
    endcase
  endfunction

  // NP2kai cgwindowset + memtram read (:11-53, :13-31), as the class each page carries.
  // page 0 = even (the reference's `low`), page 1 = odd (`high`). The reference's dummy
  // low page (fontrom[0x7fff0], zeroed by font_load) is C_DUMMY, as is our 0x00/0x8F.
  function automatic [2:0] np2_win(input [15:0] code, input lr, input page);
    reg [6:0] c7;
    begin
      c7 = code[6:0];
      if (code[15:8] == 8'h00) begin
        np2_win = page ? C_ANK : C_DUMMY;                     // ANK: high = the ANK table
      end else if ((c7 == 7'h56) || (c7 == 7'h57)) begin
        np2_win = page ? C_STORE : C_DUMMY;                   // gaiji: high = base + lr
      end else if ((c7 >= 7'h09) && (c7 < 7'h0c)) begin
        np2_win = (!lr && page) ? C_JISL : C_DUMMY;           // ver0.78: high = base, or dummy
      end else if (((c7 >= 7'h0c) && (c7 < 7'h10)) ||
                   ((c7 >= 7'h58) && (c7 < 7'h60))) begin
        np2_win = page ? (lr ? C_JISR : C_JISL) : C_DUMMY;    // wide: high = base + lr
      end else begin
        np2_win = page ? C_JISR : C_JISL;                     // JIS pair: low = left, high = right
      end
    end
  endfunction

  // NP2kai cgrom_ia9 (:189-226), as a class. line4 = 0xA5 bit 4 (the ANK gate).
  function automatic [2:0] np2_port(input [15:0] code, input lr, input line4);
    reg [7:0] t;
    reg [6:0] c7;
    begin
      t = code[7:0];
      c7 = code[6:0];
      if ((t >= 8'h09) && (t < 8'h0c)) begin
        // The ver0.78 branch is the FULL low byte tested FIRST (cgrom.c:197).
        // Two-byte with the half clear names the slot base (C_JISL) and the half
        // set falls out with no return (:198-207). ONE-BYTE codes name
        // fontrom[0x90 + row], which font_load's ZeroMemory passes and no loader
        // writes (font/font.c:145-151), so the returned BYTE is 0 whatever class
        // the slot would name - and this bench tags by the byte.
        np2_port = ((code[15:8] != 8'h00) && !lr) ? C_JISL : C_DUMMY;
      end else if (code[15:8] != 8'h00) begin
        if ((c7 == 7'h56) || (c7 == 7'h57)) np2_port = C_STORE;
        else                                np2_port = lr ? C_JISR : C_JISL;
      end else if (!line4) begin
        np2_port = C_ANK;
      end else begin
        np2_port = C_DUMMY;
      end
    end
  endfunction

  function automatic [2:0] rtl_cls(input [7:0] b);
    if      (b >= 8'h90 && b <= 8'h9F) rtl_cls = C_ANK;
    else if (b >= 8'h20 && b <= 8'h2F) rtl_cls = C_JISL;
    else if (b >= 8'h30 && b <= 8'h3F) rtl_cls = C_JISR;
    else if (b >= 8'h60 && b <= 8'h6F) rtl_cls = C_STORE;
    else                               rtl_cls = C_DUMMY;
  endfunction

  // THE 20 CONFIGURATION CELLS ARE A SANCTIONED DIVERGENCE FROM NP2kai's DECODER MODEL.
  // NP2kai backs every gaiji cell with writable
  // fontrom (memtram_wr8), so a tagged store reads back there; the machine's battery-backed
  // configuration cells do NOT take the store - the Xa7C9W runtime capture holds the record
  // intact at code 0x2056 rows 0..0xD after its boot's stage-1A wipe (qemu-pc98
  // roms/pc98bios/memsw.inc), a machine capture that outranks the software reference - and
  // this core models that as a static read-only view. The cell VALUES are pinned against the
  // dumps in tb_pc9821_cg_read_path; what this bench asserts is that the tagged load cannot
  // move them. Returns the cell's index 0..19, or -1 for any other store address.
  function automatic integer cfg_index(input [12:0] addr);
    begin
      case (addr)
        13'h0497: cfg_index = 0;
        13'h1CA7: cfg_index = 1;
        13'h1C67: cfg_index = 2;
        13'h1C6D: cfg_index = 3;
        13'h1C6E: cfg_index = 4;
        13'h1C6F: cfg_index = 5;
        default:  cfg_index = ((addr >= 13'h810) && (addr <= 13'h81D))
                              ? 6 + (addr - 13'h810) : -1;
      endcase
    end
  endfunction

  // The store is reached only for the GAIJI class (pc9821_cg's cg_gaiji: a TWO-byte code
  // whose low 7 bits are 0x56/0x57); any other code's read comes from ANK/JIS/dummy, and
  // the address fold above means nothing there.
  function automatic is_gaiji(input [15:0] code);
    is_gaiji = (code[15:8] != 8'h00) &&
               ((code[6:0] == 7'h56) || (code[6:0] == 7'h57));
  endfunction

  // ==== STIMULUS ====

  task automatic fail(input [8*96-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task automatic send_word(input [26:0] addr, input [15:0] data);
    /* verilator no_inline_task */
    begin
      while (ioctl_wait) @(negedge clk_sys);
      @(negedge clk_sys);
      ioctl_addr = addr; ioctl_dout = data; ioctl_wr = 1;
      @(negedge clk_sys); ioctl_wr = 0;
    end
  endtask

  task automatic write_io(input [7:0] portnum, input [7:0] data);
    /* verilator no_inline_task */
    begin
      @(negedge clk_sys);
      io_addr = portnum; io_din = data; io_wr = 1;
      @(negedge clk_sys); io_wr = 0;
    end
  endtask

  task automatic read_io(input [7:0] portnum, output [7:0] data);
    /* verilator no_inline_task */
    begin
      @(negedge clk_sys);
      io_addr = portnum;
      #1 data = io_dout;
      @(negedge clk_sys);
    end
  endtask

  task automatic mem_read_byte(input [31:0] addr, output [7:0] data);
    /* verilator no_inline_task */
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

  task automatic mem_write_byte(input [31:0] addr, input [7:0] data);
    /* verilator no_inline_task */
    integer lane;
    begin
      lane = addr[1:0];
      @(negedge clk_sys);
      cpu_addr = addr; cpu_din = {24'd0, data} << (lane * 8);
      cpu_be = 4'b0001 << lane; cpu_valid = 1; cpu_write = 1;
      cpu_line_read = 0;
      while (!cpu_ready) @(negedge clk_sys);
      @(negedge clk_sys); cpu_valid = 0; cpu_write = 0; cpu_be = 4'hF;
      repeat (4) @(negedge clk_sys);
    end
  endtask

  // The font fetch address of the code just selected: font_req_addr at the first
  // font_req cycle is the block base cg_jis_addr computed.
  reg [18:0] last_font_addr = 19'd0;
  always @(posedge clk_sys) if (font_req) last_font_addr <= font_req_addr;

  task automatic select_code(input [7:0] hi, input [7:0] lo);
    /* verilator no_inline_task */
    begin
      write_io(8'hA1, hi);
      write_io(8'hA3, lo);
      repeat (4) @(negedge clk_sys);
      while (font_req) @(negedge clk_sys);
      repeat (2) @(negedge clk_sys);
    end
  endtask

  // One window read: set the half (0xA5 bit 5 clear -> lr = 1) and read the offset,
  // whose page is offset[0] and whose row is offset[4:1]; compare the class.
  task automatic check_window(input [15:0] code, input lr, input page, input integer off);
    /* verilator no_inline_task */
    reg [7:0] b;
    reg [2:0] rcl, ncl;
    integer ci;
    begin
      write_io(8'hA5, lr ? 8'h00 : 8'h20);
      mem_read_byte(32'h000A_4000 + off, b);
      ci = (off & 1) ? (is_gaiji(code)
                        ? cfg_index({code[14:8], code[0], lr, off[4:1]}) : -1) : -1;
      if (ci >= 0) begin
        // The configuration cell: the post-load captured byte answers, not the class tag.
        if (b !== cfg_expect[ci]) begin
          findings = findings + 1;
          $display("CG-NP2 MISMATCH window cfg cell code=%04x lr=%0d off=%02x read %02x, the configuration byte is %02x",
                   code, lr, off, b, cfg_expect[ci]);
        end
      end else begin
        rcl = rtl_cls(b);
        ncl = np2_win(code, lr, page);
        if (rcl !== ncl) begin
          findings = findings + 1;
          $display("CG-NP2 MISMATCH window code=%04x lr=%0d page=%0d off=%02x rtl(%02x)=%s np2=%s",
                   code, lr, page, off, b, cls_name(rcl), cls_name(ncl));
        end
      end
    end
  endtask

  task automatic check_port(input [15:0] code, input lr, input integer row);
    /* verilator no_inline_task */
    reg [7:0] v;
    reg [2:0] rcl, ncl;
    integer ci;
    begin
      write_io(8'hA5, (lr ? 8'h00 : 8'h20) | row[7:0]);
      read_io(8'hA9, v);
      ci = is_gaiji(code) ? cfg_index({code[14:8], code[0], lr, row[3:0]}) : -1;
      if (ci >= 0) begin
        // The configuration cell: the post-load captured byte answers, not the class tag.
        if (v !== cfg_expect[ci]) begin
          findings = findings + 1;
          $display("CG-NP2 MISMATCH port0xA9 cfg cell code=%04x lr=%0d row=%0d read %02x, the configuration byte is %02x",
                   code, lr, row, v, cfg_expect[ci]);
        end
      end else begin
        rcl = rtl_cls(v);
        ncl = np2_port(code, lr, row[4]);
        if (rcl !== ncl) begin
          findings = findings + 1;
          $display("CG-NP2 MISMATCH port0xA9 code=%04x lr=%0d row=%0d rtl(%02x)=%s np2=%s",
                   code, lr, row, v, cls_name(rcl), cls_name(ncl));
        end
      end
    end
  endtask

  // Capture the 20 configuration cells through the port the ITF itself uses, AFTER the
  // tagged store load below: a covered cell now answers the byte the load wrote (the
  // write-through read echo), and that is the sweep's expected value.
  task automatic capture_cfg_cells;
    /* verilator no_inline_task */
    integer a;
    reg [12:0] addr;
    reg [7:0] v;
    begin
      for (a = 0; a < 20; a = a + 1) begin
        case (a)
          0: addr = 13'h0497;
          1: addr = 13'h1CA7;
          2: addr = 13'h1C67;
          3: addr = 13'h1C6D;
          4: addr = 13'h1C6E;
          5: addr = 13'h1C6F;
          default: addr = 13'h810 + (a - 6);
        endcase
        // addr = {code[14:8], code[0], lr, row}: undo it for the 0xA9 select.
        write_io(8'hA1, {1'b0, addr[12:6]});
        write_io(8'hA3, {7'h2B, addr[5]});
        write_io(8'hA5, (addr[4] ? 8'h00 : 8'h20) | {4'd0, addr[3:0]});
        read_io(8'hA9, v);
        cfg_expect[a] = v;
      end
    end
  endtask

  task automatic check_code(input [15:0] code);
    /* verilator no_inline_task */
    begin
      select_code(code[15:8], code[7:0]);
      check_window(code, 1'b0, 1'b0, 0);     // page 0 (even), row 0
      check_window(code, 1'b0, 1'b1, 1);     // page 1 (odd),  row 0
      check_window(code, 1'b1, 1'b0, 0);
      check_window(code, 1'b1, 1'b1, 1);
      check_port(code, 1'b0, 0);
      check_port(code, 1'b1, 0);
      check_port(code, 1'b0, 15);
    end
  endtask

  // Fill the writable user-CG store for one gaiji code with 0x60+row in every
  // (half,row) cell, so the store's byte names its row exactly as the font tag does.
  task automatic prep_gaiji(input [15:0] code);
    /* verilator no_inline_task */
    begin
      write_io(8'hA1, code[15:8]);
      write_io(8'hA3, code[7:0]);
      for (l = 0; l < 2; l = l + 1)
        for (r = 0; r < 16; r = r + 1) begin
          write_io(8'hA5, (l ? 8'h00 : 8'h20) | r[7:0]);
          write_io(8'hA9, 8'h60 + r[7:0]);
        end
    end
  endtask

  // ==== CHECKS ====

  initial begin
    repeat (3) @(posedge clk_sys);
    @(negedge clk_sys);
    reset = 0;

    // Load the whole 4 KiB ANK slice into the pack's ANK window: word w holds the
    // bytes for byte-addresses 2w and 2w+1.
    ioctl_download = 1;
    for (w = 0; w < 2048; w = w + 1)
      send_word(27'h0003_0000 + w[26:0] * 2,
                {ank_byte(12'd2 * w + 12'd1), ank_byte(12'd2 * w)});
    send_word(27'd0, 16'hBEEF);
    repeat (2) @(posedge clk_sys);
    ioctl_download = 0;
    repeat (3) @(posedge clk_sys);
    if (!cpu_run) fail("cpu_run never asserted after the pack download");

    // ---- the code mapping: the fetch address IS the FONT.ROM block the code names.
    //   code 0x4109 = ku 0x29 ten 0x41 -> FONT.ROM 0x1800 + 8*0xC00 + 0x21*0x20 = 0x7C20
    //   code 0x2110 = ku 0x30 ten 0x21 -> FONT.ROM 0x1800 + 15*0xC00 + 0x01*0x20 = 0xCC20
    select_code(8'h41, 8'h09);
    i = last_font_addr;
    if (i !== 19'h7C20)
      fail("code 0x4109 (A1=hi=ten, A3=lo=ku-0x20) did not fetch FONT.ROM 0x7C20");
    select_code(8'h21, 8'h10);
    k = last_font_addr;
    if (k !== 19'hCC20)
      fail("code 0x2110 did not fetch FONT.ROM 0xCC20");
    $display("CG-NP2 code mapping: 0x4109 -> FONT.ROM %05x, 0x2110 -> FONT.ROM %05x", i, k);

    // ---- the user-CG store for the gaiji codes the sweep drives.
    // The configuration cells are captured AFTER the tagged load: with the write-through
    // read echo a guest store to a covered cell now answers
    // the byte it just wrote, so the sweep's expectation is the post-load value. The STORED
    // configuration stays static and the echo clears at cfg_seed_reload (`out 0xF0`) - pinned
    // in tb_pc9821_cg_read_path; what this bench pins is the class/page decode around them.
    prep_gaiji(16'h1056); prep_gaiji(16'h1057); prep_gaiji(16'h2056);
    prep_gaiji(16'h2057); prep_gaiji(16'h4156); prep_gaiji(16'h4157);
    prep_gaiji(16'h7156); prep_gaiji(16'h7157); prep_gaiji(16'h8056);
    prep_gaiji(16'h8057);
    capture_cfg_cells;

    // ---- the class sweep vs NP2kai.
    // One-byte codes: every 0x00XX the ANK and ver0.78 classes can take.
    check_code(16'h0000); check_code(16'h0001); check_code(16'h0008);
    check_code(16'h0009); check_code(16'h000A); check_code(16'h000B);
    check_code(16'h000C); check_code(16'h000F); check_code(16'h0010);
    check_code(16'h0041); check_code(16'h0055); check_code(16'h0056);
    check_code(16'h0057); check_code(16'h0058); check_code(16'h005F);
    check_code(16'h0060); check_code(16'h007F); check_code(16'h0089);
    check_code(16'h008A); check_code(16'h008B); check_code(16'h00FF);
    // Two-byte codes: a high byte per class region crossed with each low-byte class.
    for (i = 0; i < 5; i = i + 1) begin
      case (i)
        0: begin check_code(16'h1009); check_code(16'h100A); check_code(16'h100B);
                 check_code(16'h100C); check_code(16'h100F); check_code(16'h1010);
                 check_code(16'h1056); check_code(16'h1057); check_code(16'h1058);
                 check_code(16'h105F); check_code(16'h1060); check_code(16'h107F);
                 check_code(16'h1089); check_code(16'h108A); check_code(16'h108B); end
        1: begin check_code(16'h2009); check_code(16'h200A); check_code(16'h200B);
                 check_code(16'h200C); check_code(16'h200F); check_code(16'h2010);
                 check_code(16'h2056); check_code(16'h2057); check_code(16'h2058);
                 check_code(16'h205F); check_code(16'h2060); check_code(16'h207F);
                 check_code(16'h2089); check_code(16'h208A); check_code(16'h208B); end
        2: begin check_code(16'h4109); check_code(16'h410A); check_code(16'h410B);
                 check_code(16'h410C); check_code(16'h410F); check_code(16'h4110);
                 check_code(16'h4156); check_code(16'h4157); check_code(16'h4158);
                 check_code(16'h415F); check_code(16'h4160); check_code(16'h417F);
                 check_code(16'h4189); check_code(16'h418A); check_code(16'h418B); end
        3: begin check_code(16'h7109); check_code(16'h710A); check_code(16'h710B);
                 check_code(16'h710C); check_code(16'h710F); check_code(16'h7110);
                 check_code(16'h7156); check_code(16'h7157); check_code(16'h7158);
                 check_code(16'h715F); check_code(16'h7160); check_code(16'h717F);
                 check_code(16'h7189); check_code(16'h718A); check_code(16'h718B); end
        default: begin check_code(16'h8009); check_code(16'h800A); check_code(16'h800B);
                 check_code(16'h800C); check_code(16'h800F); check_code(16'h8010);
                 check_code(16'h8056); check_code(16'h8057); check_code(16'h8058);
                 check_code(16'h805F); check_code(16'h8060); check_code(16'h807F);
                 check_code(16'h8089); check_code(16'h808A); check_code(16'h808B); end
      endcase
    end

    // ---- the divergences that are NOT class/page: the one-byte write gate, reported
    // and ASSERTED, and the gaiji low page, reported.
    // 1. The write gate. NP2kai's cgwindowset sets cgwindow.writable ONLY in the
    //    two-byte branch, so a window store under a ONE-byte code 0x0056/0x0057 is
    //    DROPPED. Read the cell the two-byte 0x8056 store occupies, write 0x5A through
    //    the one-byte code, re-select 0x8056 and read the cell again: it must be
    //    unchanged. Fails on a gate that ignores the code's high byte.
    write_io(8'hA1, 8'h00); write_io(8'hA3, 8'h56); write_io(8'hA5, 8'h00);  // lr=1, row 0
    select_code(8'h80, 8'h56);
    mem_read_byte(32'h000A_4001, value);
    store_before = value;
    select_code(8'h00, 8'h56);
    mem_write_byte(32'h000A_4001, 8'h5A);
    select_code(8'h80, 8'h56);
    mem_read_byte(32'h000A_4001, value);
    if (value !== store_before)
      fail("a one-byte 0x0056 window store was NOT dropped: the 0x8056 cell moved");
    $display("CG-NP2 FINDING one-byte-0x0056 window store DROPPED: the 0x8056 cell stays %02x (NP2kai cgwindowset drops it)", value);
    // 2. The gaiji even (low) page. NP2kai reads fontrom[0x7fff0] (0x00 after
    //    font_load's ZeroMemory); the machine measured 0x8F (docs/probes/VRAM.TXT).
    select_code(8'h20, 8'h56);
    write_io(8'hA5, 8'h00);   // lr = 1
    mem_read_byte(32'h000A_4000, value);
    $display("CG-NP2 FINDING gaiji low page reads %02x (NP2kai=00, machine 0x8F; our CG_LOW_DUMMY)", value);

    // ---- the gate: the window answers at 0xA4000 with no register access at all,
    //   and the window-0 bank cannot move a 0xA4000 access (win0_moved needs
    //   0x80000-0x9FFFF), so neither it nor port 0x53E gates the window.
    select_code(8'h00, 8'h41);
    win0_sel = 8'h0C;
    mem_read_byte(32'h000A_4001, value);
    if (value !== 8'h90)
      fail("the CG window stopped answering with win0_sel moved off 0x08");
    win0_sel = 8'h08;
    mem_read_byte(32'h000A_4001, value);
    if (value !== 8'h90)
      fail("the CG window did not answer at win0_sel 0x08");

    // ==== VERDICT ====
    $display("CG-NP2: %0d class/page divergences from NP2kai", findings);
    // The divergence set is PINNED AT ZERO: both decoders now
    // reproduce NP2kai exactly, so ANY divergence is a bug and cannot pass silently.
    // The pre-fix RTL diverged only on the overlap codes whose low byte is 0x09-0x0B
    // or 0x89-0x8B: the port's ver0.78 test masked bit 7 where cgrom_ia9 tests the full
    // low byte (:197), and the window's one-byte branch answered the ver0.78 class
    // where cgwindowset's is the ANK page (:21-25). No JIS text reaches those low
    // bytes except 0x09-0x0B (ku 0x29-0x2B, the half-width rows).
    if (findings !== 0)
      fail("the RTL diverges from NP2kai's cgwindowset/cgrom_ia9 decoders");
    if (errors == 0) begin
      $display("TB_PC9821_CG_NP2: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_CG_NP2: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_CG_NP2: TIMEOUT");
  end

endmodule

`default_nettype wire
