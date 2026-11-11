`timescale 1ns/1ps

// Unit bench for the memory-mapped CG window, 0xA4000-0xA4FFF.
//
// The contract asserted here is the hardware's, and where each expectation
// comes from is stated with it:
//
//   * The window is not RAM: it is a 32-byte repeating view of the glyph the CG
//     registers (ports 0xA1 code high / 0xA3 code low / 0xA5 row+half) select,
//     and the row is address bits [4:1]. Even offsets show the reference's
//     "low" page, odd offsets its "high" page, and the whole 4 KiB repeats
//     every 32 bytes. Sources: qemu-pc98/hw/display/pc98-vga.c
//     cgwindow_set_addr/readb/writeb (:2913-3074) and NP2kai/mem/memtram.c
//     (:13-101). Both agree on the 32-byte grain and on row = addr>>1 & 0xf.
//   * The window and port 0xA9 share one store, so a byte written through
//     either appears through the other for the selected glyph. Sources:
//     qemu cgwindow_pattern_write/read (:2995-3026) and NP2kai cgrom_oa9/ia9
//     (:176-232) write/read the same font[] the window addresses.
//   * Only a code whose low byte is 0x56/0x57 is writable, and for it the odd
//     (high) offsets are the real storage while the even (low) offsets land on
//     the reference's dummy page (qemu cgwindow_writeb gate, NP2kai
//     memtram_wr8:98-102).
//   * The window exists only at 0xA4000-0xA4FFF in the first MiB: an access
//     just outside it is NOT the window's. Just past its top the MACHINE has an
//     absent region, not ordinary memory: 0xA5000-0xA7FFF reads 0xFF and
//     discards stores (docs/probes/VRAM.TXT:141-142, `A600wrote= 00 FF 55 AA` /
//     `got= FF FF FF FF`, reproduced in VRAM2.TXT:153-154, with the
//     neighbouring A000/A200 TRAM and A800/B000/B800 plane rows round-tripping
//     in the same capture), and the core routes it to the registered open-bus
//     responder (pc9821_memory_subsystem.sv's tram_gap). That is the "must not
//     capture the GVRAM/other apertures" requirement in its measured form; the
//     ITF itself uses the window as scratch glyph memory (BANK4@0xFC677-0xFC686,
//     which is the check this window unblocks).
//
// The window and port 0xA9 are one glyph view in two shapes. The class table
// and every store live in the GDC; this module owns the CPU-side responder and
// the byte *position* ({page, row}) and lets the GDC name the byte, so the two
// views cannot disagree. The ROM glyph classes (the ANK table, and the JIS
// blocks a two-byte code selects) are asserted by tb_pc9821_cg_read_path, which
// supplies their glyph data.
//
// The test drives the window *through the memory subsystem's CPU port*, never
// by poking RTL internals, and cross-checks the port-0xA9 view through the real
// pc9821_gdc_text. The GDC and memory subsystem are wired exactly as
// pc9821_system.sv wires them.

`default_nettype none

// ==== WHAT THIS PROVES ====
// The memory-mapped CG window at 0xA4000: a 32-byte repeating view of the glyph the CG registers select, the user CG RAM write/read path, the code registers packing as A1 high / A3 low, the decode boundary at 0xA5000, a ready-then-response phase, and the ITF configuration record present on a fresh power-up store (the marker at window offsets 0x11/0x13 and the ten bytes the ITF sums, read before anything writes them). It does NOT cover the ROM glyph classes: the ANK page is answered from the pack slice by tb_pc9821_cg_read_path. The even/low page is ASSERTED at the dummy byte the machine itself measures, 0x8F (docs/probes/VRAM.TXT, exactly this class; NP2kai has one dummy page shared by every class, io/cgrom.c:18): a store there vanishes and a read answers 0x8F.
//
// The memory-mapped CG window at 0xA4000: a 32-byte repeating view of the glyph the CG registers select, the user CG RAM write/read path, the code registers packing as A1 high / A3 low, the decode boundary at 0xA5000, a ready-then-response phase, and the ITF configuration record present on a fresh power-up store (the marker at window offsets 0x11/0x13 and the ten bytes the ITF sums, read before anything writes them). It does NOT cover the ROM glyph classes: the ANK page is answered from the pack slice by tb_pc9821_cg_read_path. The even/low page is ASSERTED at the machine's measured dummy 0x8F (docs/probes/VRAM.TXT, exactly this class; NP2kai has one dummy page shared by every class, io/cgrom.c:18) - the old reported-only note tracked a zero-read model both references contradicted.


module tb_pc9821_cg_window;
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
  // EGC held disabled: this bench owns the CG window, not the graphics engine
  // (tb_pc9821_egc.sv is where that is driven).
  reg        egc_enable = 1'b0;
  reg [15:0] egc_access = 16'hFFF0;
  reg [15:0] egc_fgbg = 16'h00FF;
  reg [15:0] egc_ope = 16'h0000;
  reg [15:0] egc_fg = 16'h0000;
  reg [15:0] egc_mask = 16'hFFFF;
  reg [15:0] egc_bg = 16'h0000;
  reg [15:0] egc_sft = 16'h0000;
  reg [15:0] egc_leng = 16'h000F;
  reg        egc_shift_we = 1'b0;
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

  // Shared CG byte channel between the subsystem's window responder and the GDC.
  wire [4:0] cg_win_byte_sel;
  wire cg_win_rd;
  wire [7:0] cg_win_dout;
  wire [7:0] cg_win_din;
  wire cg_win_we;
  // Glyph-region fetch to the SDRAM's second port: answered by the stub below.
  reg [18:0] font_req_addr = 0;
  reg font_req = 0;
  reg font_word_valid = 0;
  reg [31:0] font_word_data = 32'd0;
  wire [31:0] fmem_addr, fmem_din;
  wire fmem_valid, fmem_write;
  wire [3:0] fmem_be;
  wire [7:0] fmem_burstcount;
  reg fmem_ready = 1, fmem_resp_valid = 0;
  reg [31:0] fmem_dout = 32'd0;

  // Backend (SDRAM) stub.
  wire [31:0] mem_addr, mem_din, mem_din_hi;
  reg [31:0] mem_dout = 32'hDEAD_BEEF;
  reg [127:0] mem_line_dout = 128'h0123_4567_89AB_CDEF_FEDC_BA98_7654_3210;
  wire [3:0] mem_be;
  wire [7:0] mem_burstcount;
  wire mem_line_read, mem_valid, mem_write;
  reg mem_ready = 1, mem_resp_valid = 0, mem_line_resp_valid = 0;

  integer backend_writes = 0;
  reg [31:0] backend_last_addr = 0;
  integer window_hits = 0;
  always @(posedge clk_sys) begin
    if (mem_valid && mem_ready) begin
      backend_last_addr <= mem_addr;
      if (mem_write) backend_writes <= backend_writes + 1;
    end
    // A window access must never leave for the backend.
    if (cg_win_rd && mem_valid) window_hits <= window_hits + 1;
  end

  // ---- memory subsystem (window responder integrated into its arbitration)
  // ==== DUT ====
  // Two blocks, because this window spans both, wired exactly as
  // pc9821_system.sv wires them.
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
      .egc_enable(egc_enable), .egc_access(egc_access), .egc_fgbg(egc_fgbg),
      .egc_ope(egc_ope), .egc_fg(egc_fg), .egc_mask(egc_mask),
      .egc_bg(egc_bg), .egc_sft(egc_sft), .egc_leng(egc_leng),
      .egc_shift_we(egc_shift_we),
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

  // ---- GDC owning the store and the 0xA9 port -------------------------
  reg io_wr = 0;
  reg [7:0] io_addr = 0, io_din = 0;
  wire [7:0] io_dout;
  wire gfx_access_page_t;
  wire vsync_active, disp_on, vsync_irq;
  reg vsync_irq_arm = 0;
  wire [15:0] dbg_sad;
  wire [7:0] dbg_pitch;
  wire dbg_col40, dbg_disp;
  wire v_hs, v_vs, v_de;

  pc9821_gdc_text_dut dut_gdc (
      .clk_sys(clk_sys), .rst_n_sys(!reset),
      .cfg_fdd_mode(3'd0),   // entry 0: the measured boot/FDD nibble
      .pixel_ce(1'b1),
      .io_wr(io_wr), .io_rd(1'b0), .io_addr(io_addr), .io_din(io_din), .io_dout(io_dout),
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

  // A same-cycle ready+resp_valid answer wedges z486, and two sequential waits cannot
  // tell the phases apart -- both pass with it.
  always @(posedge clk_sys)
    if (cpu_ready && (cpu_resp_valid || cpu_line_word_valid))
      $fatal(1, "ready and response in the same cycle");

  reg [7:0] rval;
  reg [7:0] record_after_reset, record_tail_after_reset;
  // The backend's last accepted address, memo'd around an access: the stub records it on
  // every accept (mem_valid && mem_ready), so "did this access reach the ordinary backend
  // at all" is a comparison, not a count - the count only tracks WRITES.
  reg [31:0] backend_addr_before;
  integer   sum_stride1, sum_stride2, sum_powerup;
  // The configuration record the authentic ITF writes and checks. Double-sourced:
  // BANK4@0x4924 with its count byte at 0x4923, and QEMU's pc98bios/memsw.inc
  // replayed from a real Xa7C9W. It sums to zero mod 256, which is what makes it
  // a valid record.
  localparam [7:0] RECORD_BYTES [0:9] = '{8'hc1, 8'h8c, 8'h81, 8'hcd, 8'hff,
                                          8'h00, 8'h00, 8'haa, 8'h55, 8'h67};
  // The record a fresh power-up store holds: the factory table above with the one item the
  // owner's Xe10 as found differs in, Sound "not used" (docs/bios-setup.md "The Xe10 as
  // found"; its 0x881E reads 0x7C in docs/probes/XE10CFG-XE10-CFG0.TXT). SETUP stores that
  // item in row 4 bit 1, 1 = not used, so row 4 is 0xcf; and GDC clock 2.5 MHz, which SETUP
  // stores in row 2 bit 7 inverted (the getter BANK3@0x37A3 `call 0x20db / shr al,0x7`, value
  // 1 = 2.5 MHz; this bench's setup_cfg 0x763EF3 is that machine), so row 2 is 0x0c. The
  // completing byte is 0x67 - 2 + 0x80 = 0xe5, and the sum is still 0x500.
  // pc9821_cg.sv's CG_RECORD_INIT.
  localparam [7:0] POWERUP_RECORD [0:9] = '{8'hc1, 8'h0c, 8'h81, 8'hcf, 8'hff,
                                            8'h00, 8'h00, 8'haa, 8'h55, 8'he5};
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

  // Write one byte through the CPU memory port; the byte goes in its lane.
  task automatic mem_write_byte(input [31:0] addr, input [7:0] data);
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

  // Read one byte through the CPU memory port.
  task automatic mem_read_byte(input [31:0] addr, output [7:0] data);
    integer lane;
    begin
      lane = addr[1:0];
      @(negedge clk_sys);
      cpu_addr = addr; cpu_be = 4'hF; cpu_valid = 1; cpu_write = 0;
      cpu_line_read = 0;
      while (!cpu_ready) @(negedge clk_sys);
      // The responder delivers data with cpu_resp_valid, one cycle after the
      // accept (z486 samples din on the response, matching the open-bus
      // responder). Sample where the data is valid.
      while (!cpu_resp_valid && !cpu_line_word_valid) @(negedge clk_sys);
      #1 data = cpu_dout[lane*8 +: 8];
      @(negedge clk_sys); cpu_valid = 0;
      repeat (4) @(negedge clk_sys);
    end
  endtask

  // Select the glyph: A1 = code high, A3 = code low, A5 = row + half.
  task automatic select_code(input [7:0] hi, input [7:0] lo, input [7:0] a5);
    begin
      write_io(8'hA1, hi);
      write_io(8'hA3, lo);
      write_io(8'hA5, a5);
    end
  endtask
  // ==== CHECKS ====

  initial begin
    repeat (3) @(posedge clk_sys);
    @(negedge clk_sys);
    reset = 0;

    // Release the CPU: the subsystem owns the backend until a pack word lands
    // and rom_ready rises (same sequencing the subsystem's own bench uses).
    ioctl_download = 1;
    send_word(27'd0, 16'hBEEF);
    repeat (2) @(posedge clk_sys);
    ioctl_download = 0;
    repeat (3) @(posedge clk_sys);
    if (!cpu_run) begin
      fail("cpu_run never asserted after the pack download");
    end

    // ---------------------------------------------------------------
    // 0. The software-DIP configuration record is present on a FRESH power-up
    //    store, before anything in this bench writes to it. The machine's CG
    //    store is battery-backed, so the record the ITF checks at 0xFC681 is
    //    already there before the guest runs; this core's array comes up
    //    zeroed unless it is seeded. The read below is the ITF's own: code
    //    0x2056 (0xA1 = 0x20, 0xA3 = 0x56), A5 with bit 5 CLEAR so cg_lr = 1,
    //    window offsets 3,5,...,0x15 = store 0x811..0x81A.
    //    Where the contract comes from: BANK4@0xFC677/0xFC67D read es:0x11 into
    //    AH and es:0x13 into AL and compare against 0xAA55 at 0xFC681, then
    //    BANK4@0xFC699-0xFC6B5 adds the ten bytes at es:[3],[5],...,[0x15] into
    //    BL and requires the 8-bit sum to be zero; the ten bytes are this
    //    machine's own ITF table (count 0x0A at BANK4@0x4923, bytes at 0x4924)
    //    with Sound "not used" in row 4 (POWERUP_RECORD above).
    //    The section below (3b) writes the record through the same window, which
    //    is why it cannot catch a store that powers up zeroed -- these
    //    assertions must run first, and they do.
    // ---------------------------------------------------------------
    select_code(8'h20, 8'h56, 8'h08);        // code 0x2056, A5 bit 5 clear -> lr = 1
    mem_read_byte(32'h000A_4011, rval);
    if (rval !== 8'hAA)
      fail("power-up record: marker high byte at window offset 0x11");
    mem_read_byte(32'h000A_4013, rval);
    if (rval !== 8'h55)
      fail("power-up record: marker low byte at window offset 0x13");
    sum_powerup = 0;
    for (integer k = 0; k < 10; k = k + 1) begin
      mem_read_byte(32'h000A_4000 + 3 + k * 2, rval);
      if (rval !== POWERUP_RECORD[k])
        fail("power-up record byte at the ITF's own window offset");
      sum_powerup = sum_powerup + rval;
    end
    // Both forms, because both are what the firmware checks: the ten bytes sum
    // to 0x500, and the ITF only looks at the low byte (BL == 0).
    if (sum_powerup[7:0] !== 8'h00)
      fail("power-up record sum is not zero mod 256 (the ITF's own test)");
    if (sum_powerup !== 16'h0500)
      fail("power-up record sum is not 0x500");

    // ---------------------------------------------------------------
    // 1. Window write -> 0xA9 read, for the selected user-CG glyph.
    //    code 0x1056 (A1=0x10, A3=0x56), row 3, A5 bit5=0 -> right half.
    //    Offset 0x07 is odd -> high page, row (7>>1)&0xf = 3.
    // ---------------------------------------------------------------
    select_code(8'h10, 8'h56, 8'h03);
    mem_write_byte(32'h000A_4007, 8'h5A);
    read_io(8'hA9, rval);
    if (rval !== 8'h5A)
      fail("window write did not appear at port 0xA9");

    // ---------------------------------------------------------------
    // 2. 0xA9 write -> window read (the other direction), and the 32-byte
    //    repeat: offsets 0x07, 0x27, 0x47, ... are the same row of the same
    //    glyph, so they must all read the same byte.
    // ---------------------------------------------------------------
    write_io(8'hA9, 8'h3C);
    mem_read_byte(32'h000A_4007, rval);
    if (rval !== 8'h3C)
      fail("0xA9 write did not appear in the window at offset 0x07");
    mem_read_byte(32'h000A_4027, rval);
    if (rval !== 8'h3C) fail("window 32-byte repeat (0x07 vs 0x27)");
    mem_read_byte(32'h000A_4047, rval);
    if (rval !== 8'h3C) fail("window 32-byte repeat (0x07 vs 0x47)");
    mem_read_byte(32'h000A_4FE7, rval);
    if (rval !== 8'h3C) fail("window 32-byte repeat across the whole 4 KiB");

    // ---------------------------------------------------------------
    // 3. Even offsets of a user-CG code are the dummy page: a store there must
    //    vanish (the capture's even writes were dropped) and the read must answer
    //    the machine's class-independent dummy 0x8F, without disturbing the odd
    //    byte that port 0xA9 also sees.
    // ---------------------------------------------------------------
    mem_write_byte(32'h000A_4006, 8'h77);
    mem_read_byte(32'h000A_4006, rval);
    // ASSERTED: the machine measured 0x8F here in exactly this
    // class (docs/probes/VRAM.TXT: even writes dropped, even reads 0x8F) and NP2kai
    // has ONE dummy page shared by every class (io/cgrom.c:18,43-48).
    if (rval !== 8'h8F)
      fail("the even/low page is not the machine's dummy 0x8F: a store there must vanish");

    mem_read_byte(32'h000A_4007, rval);
    if (rval !== 8'h3C) fail("even-offset write clobbered the odd-offset byte");

    // ---------------------------------------------------------------
    // 3b. The shape the authentic ITF uses. Its repair writes the configuration
    //     record `c1 8c 81 cd ff 00 00 aa 55 67` (double-sourced: BANK4@0x4924 with
    //     its count byte at 0x4923, and QEMU's pc98bios/memsw.inc from a real
    //     Xa7C9W) at odd window offsets 3..0x15, and its marker check reads offsets
    //     0x11 and 0x13 expecting AA and 55. Both the offsets and the bytes are fixed
    //     by the firmware, not by this core, so this is the contract the boot needs.
    //
    //     The ITF's sum loop reads the odd offsets 3,5,...,0x15 with DI += 2
    //     (`47 47` at BANK4@0xFC69F, ten iterations from 0xFC699) into BL, 8-bit
    //     wrapping, and requires the result zero (BANK4@0xFC6B3). An earlier
    //     reading of this loop -- "stride 1 over offsets 1..10" -- came from the
    //     store-level probe, where one byte read is a 4-lane transfer that prints
    //     offsets 0,1,2,3; the disassembly and the two-check structure fix the
    //     stride as 2. Both sums are
    //     still printed: they are what a change in the offset mapping would move.
    //     A5 = 0x08 is the ITF's own selection (BANK4@0xFC673): bit 5 clear means
    //     cg_lr = 1, so the store is the 0x811..0x81A page the check reads -- the
    //     0x20 this section used before selects lr = 0, i.e. the OTHER page, which
    //     is why it could never have caught a missing record either.
    // ---------------------------------------------------------------
    select_code(8'h20, 8'h56, 8'h08);        // code 0x2056, A5 bit 5 clear -> lr = 1
    for (integer k = 0; k < 10; k = k + 1)
      mem_write_byte(32'h000A_4000 + 3 + k * 2, RECORD_BYTES[k]);
    for (integer k = 0; k < 10; k = k + 1) begin
      mem_read_byte(32'h000A_4000 + 3 + k * 2, rval);
      if (rval !== RECORD_BYTES[k])
        fail("configuration record byte did not read back at the ITF's offset");
    end
    mem_read_byte(32'h000A_4011, rval);
    if (rval !== 8'hAA) fail("marker high byte is not at window offset 0x11");
    mem_read_byte(32'h000A_4013, rval);
    if (rval !== 8'h55) fail("marker low byte is not at window offset 0x13");
    sum_stride1 = 0;
    for (integer k = 1; k <= 10; k = k + 1) begin
      mem_read_byte(32'h000A_4000 + k, rval);
      sum_stride1 = sum_stride1 + rval;
    end
    sum_stride2 = 0;
    for (integer k = 0; k < 10; k = k + 1) begin
      mem_read_byte(32'h000A_4000 + 3 + k * 2, rval);
      sum_stride2 = sum_stride2 + rval;
    end
    $display("CGW record sum: consecutive-offsets=%02x the-ITF's-odd-offsets=%02x (00 is the pass condition)",
             sum_stride1[7:0], sum_stride2[7:0]);
    // The ITF's own condition, after this section's own writes: the ten bytes at
    // the odd offsets sum to zero mod 256.
    if (sum_stride2[7:0] !== 8'h00)
      fail("the ten record bytes written through the window do not sum to zero");

    // ---------------------------------------------------------------
    // 3c. THE RECORD SURVIVES A WARM (OSD) RESET. The record is battery-backed on the
    //     machine, so a guest store to it must survive a platform reset. The store is
    //     a pc9821_dpram with no reset port, and its INIT power-up image runs once, so
    //     a correct core must NOT re-seed it: the reset is warm and the pack
    //     (rom_ready/cpu_run) survives it (pc9821_rom_loader keeps rom_ready across a
    //     soft reset on purpose). Write a byte the power-up image does NOT carry into a
    //     record cell (row 1 = store 0x811 via window offset 3), pulse the platform
    //     reset, and require the guest's byte back; an untouched record cell (row 0xD =
    //     store 0x81D, power-up 0xFF) must still hold its image. This is the earlier
    //     finding: the record already persists, so the ITF's repeated DIP prompt is not
    //     a re-seed --
    // ---------------------------------------------------------------
    select_code(8'h20, 8'h56, 8'h08);
    mem_write_byte(32'h000A_4003, 8'hAB);                 // store 0x811 (row 1)
    mem_read_byte(32'h000A_4003, rval);
    if (rval !== 8'hAB) fail("record write did not read back before the reset");
    mem_read_byte(32'h000A_401B, rval);                   // store 0x81D (row 0xD), untouched
    if (rval !== 8'hFF) fail("record tail (store 0x81D) is not the power-up image before the reset");
    reset = 1;
    repeat (4) @(posedge clk_sys);
    reset = 0;
    repeat (4) @(posedge clk_sys);
    if (!cpu_run) fail("the platform reset lost the pack: cpu_run low after a warm reset");
    select_code(8'h20, 8'h56, 8'h08);
    mem_read_byte(32'h000A_4003, rval);
    record_after_reset = rval;
    mem_read_byte(32'h000A_401B, rval);
    record_tail_after_reset = rval;
    if (record_after_reset !== 8'hAB)
      fail("the guest's DIP-record store did NOT survive the warm reset");
    if (record_tail_after_reset !== 8'hFF)
      fail("the untouched DIP-record byte was re-seeded across the warm reset");
    $display("CGW DIP record survives a warm reset: store 0x811 = %02x (guest-written), store 0x81D = %02x (power-up image)",
             record_after_reset, record_tail_after_reset);

    // ---------------------------------------------------------------
    // 4. The A5 bit-5 half select is part of the page address: the other half
    //    is distinct storage, and switching back keeps the first byte.
    // ---------------------------------------------------------------
    select_code(8'h10, 8'h56, 8'h23);   // row 3, bit5=1 -> left half
    mem_read_byte(32'h000A_4007, rval);
    if (rval === 8'h3C) fail("left/right halves of the window alias");
    write_io(8'hA9, 8'h11);
    mem_read_byte(32'h000A_4007, rval);
    if (rval !== 8'h11) fail("left-half 0xA9 write missing from the window");
    select_code(8'h10, 8'h56, 8'h03);
    mem_read_byte(32'h000A_4007, rval);
    if (rval !== 8'h3C) fail("right half lost its byte after a half switch");

    // ---------------------------------------------------------------
    // 5. The code's high byte selects the page: another page is other storage.
    // ---------------------------------------------------------------
    select_code(8'h11, 8'h56, 8'h03);
    mem_read_byte(32'h000A_4007, rval);
    if (rval === 8'h3C) fail("window pages alias (page 0x11 sees page 0x10)");
    select_code(8'h10, 8'h56, 8'h03);

    // ---------------------------------------------------------------
    // 6. The decode stops at 0xA4FFF in both directions: the window must not
    //    capture an access just past its top, and just past its top the MACHINE
    //    has an ABSENT region, not ordinary memory - it reads 0xFF and discards
    //    stores (docs/probes/VRAM.TXT:141-142, `A600wrote= 00 FF 55 AA` /
    //    `got= FF FF FF FF`, reproduced in VRAM2.TXT:153-154, with the
    //    neighbouring A000/A200 TRAM and A800/B000/B800 plane rows
    //    round-tripping in the same capture). The core serves 0xA5000-0xA7FFF
    //    from the registered open-bus responder (pc9821_memory_subsystem.sv's
    //    tram_gap), so the two requirements collapse into one here: no backend
    //    transaction, no window hit, the machine's all-ones answer, and the
    //    window byte at 0xA4007 untouched.
    // ---------------------------------------------------------------
    window_hits = 0;
    backend_writes = 0;
    backend_addr_before = backend_last_addr;
    mem_write_byte(32'h000A_5000, 8'h99);
    if (backend_writes != 0)
      fail("0xA5000 store reached the ordinary backend: the machine discards it");
    if (backend_last_addr !== backend_addr_before)
      fail("0xA5000 store was translated onto the ordinary backend");
    if (window_hits != 0) fail("0xA5000 store was captured by the CG window");
    mem_read_byte(32'h000A_5000, rval);
    if (rval !== 8'hFF)
      fail("0xA5000 did not answer the machine's all-ones absent value");
    if (backend_last_addr !== backend_addr_before)
      fail("0xA5000 read reached the ordinary backend");
    if (window_hits != 0) fail("0xA5000 read was captured by the CG window");
    mem_read_byte(32'h000A_4007, rval);
    if (rval !== 8'h3C) fail("window byte changed by an out-of-window store");

    // A window read just inside the boundary must be answered by the window,
    // i.e. must not touch the backend at all.
    window_hits = 0;
    backend_addr_before = backend_last_addr;
    mem_read_byte(32'h000A_4FFF, rval);
    if (window_hits != 0) fail("window-boundary read leaked to the backend");
    if (backend_last_addr !== backend_addr_before)
      fail("window-boundary read reached the ordinary backend");
  // ==== VERDICT ====

    if (errors == 0) begin
        $display("TB_PC9821_CG_WINDOW: PASS");
        $finish;
    end
    else $fatal(1, "TB_PC9821_CG_WINDOW: FAIL (%0d errors)", errors);
  end

  initial begin
    #5_000_000;
    $fatal(1, "TB_PC9821_CG_WINDOW: TIMEOUT");
  end

endmodule

`default_nettype wire
