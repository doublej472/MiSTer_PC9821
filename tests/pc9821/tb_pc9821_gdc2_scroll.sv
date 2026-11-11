`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The GDC2 command path at 0xA2/0xA0 for SCROLL: TH01's and master.lib's eight-parameter transaction lands in the graphics GDC's two display partitions, the firmware's own four-parameter transaction (BANK6@0x788F-0x78C5) leaves partition 2 alone as the machine does, the resulting display start address is the games' own (line*40 words, with partition 2 wrapping the top line in at address 0), the firmware's own CSRFORM write (0xA2 <- 0x4B then one 0xA0 byte, BANK6@0x787e-0x788c) is captured and the address counter advances one 640-dot line per raster line when its line repeat is 1 (640x400) and holds each GDC line for two raster lines when it is 2 (640x200) - the step that fills a 400-line raster from a 200-GDC-line program, keyed on the slave CSRFORM and not on mode1[4] (port 0x68 bit 4), which master.lib's own 200-line routine clears after the mode set so the two registers disagree in both directions (Thexder and Touhou shapes benched) - with the armed VSYNC IRQ still firing once per frame in the 200-line mode and the address wrapping inside the 32 KiB plane, the 0xA4 display page is bit 15 of it, and the status protocol the games and the ITF wait on (bit 2 empty, bit 1 full) reads true before, during and after the transaction, with a status read in mid-stream disturbing nothing; and the partition ARITHMETIC (datapaths.md F3/F4/F5): the partition lengths count RASTER lines with the repeat phase restarting per partition (NP2kai makegrph.c:143-167, MAME upd7220.cpp:1857-1903 - fail-first against the old GDC-line boundary at raster 2*lines1), a zero-length SECOND partition takes over at the boundary and runs to the screen end (MAME's len==0 -> 0x400, real-HW-verified), and the CSRFORM line repeat covers lr = 1..32 rather than just {1,2}; and the SCROLL length word's im bit - bit 14 of EACH partition's LENGTH word - selects that partition's address step (NP2kai vram/makegrph.c:146-148 reads it per partition from para[GDC_SCROLL + gpos + 2] and doubles the pitch at 0, MAME upd7220.cpp:611/624 takes BIT(m_ra[index * 4 + 3], 6) and pc9821.cpp:103-106 shifts by im ^ 1), which is 2 x PITCH in the machine's own im = 0 state and PITCH at the 5 MHz im = 1 a game builds from BIOS work-area 0000:054D bit 2 (rec98/th01/hardware/scrollup.cpp:22-27) - pinned in both directions, one partition's bit each way, so a hard-wired step or a swap of the two partitions' bits cannot pass. It does NOT cover the graphics scanout that consumes the address, the START/STOP/SYNC/CSRW/TEXTW/VECTW commands the firmware issues on 0xA2, or a real FIFO depth. Section 8 pins a same-cycle race (race-idiom #34): a configuration write whose strobe covers the frame_end snapshot edge is DEFERRED to the next frame end and never dropped, swept across the four clk around the snapshot edge with the bus idle in between. Section 13 pins the PACKED page flip: the SCROLL start word's bit 14 is the walk's bit 15 (gfx_walk_page - NP2kai's packed arm walks LOW16(vad << 1) over the full 512 KiB with the page in that bit, vram/makegrex.c:199; MAME's flashb note names the flip register - double buffering at SAD $38fc and $fffc - pc9821.cpp:108-113) and it takes effect at the frame boundary with the rest of the SCROLL block - the uPD7220 reads the SAD at the start of the display scanning process, the machine's full-frames swap - while the planar view ({display page, walk[14:0]}) stays bit-identical across the flip. FAIL-FIRST: the old LOW15 start decode dropped the bit, so two SADs differing only in it decoded to the same walk and gfx_walk_page never set. Sections 9/10b pin NP2kai's four-partition walk (partitions 3 and 4 are the TEXTW parameter-RAM bytes 8..15, and makegrph walks 1-2-3-4-1 until the screen is full), and section 14 pins the slave SYNC's vertical graphics window (NP2kai vram/dispsync.c dispsync_renewalvertical: the walk starts at grph_vbp = slave VBP - master VBP and the graphics end at grphymax = AL + grph_vbp). Section 16 pins the PLANAR walk's step: it is the guest's slave PITCH command (0x47) byte, doubled when the partition's im bit is clear and masked to an even byte (NP2kai vram/makegrph.c:147-151) - PITCH 80 with im = 1, the 5 MHz state NP2kai's BIOS mode set writes (bios/bios18.c:483-487), steps 80 bytes, PITCH 80 with im = 0 steps 160, and PITCH 40 is the reset 40/80 again - FAIL-FIRST against the constant 40-word pitch, which stepped 40 bytes at im = 1 whatever PITCH said and showed each line's two halves side by side.
//
// The GDC2 command path at 0xA2/0xA0 for SCROLL: TH01's and master.lib's eight-parameter transaction lands in the graphics GDC's two display partitions, the firmware's own four-parameter transaction (BANK6@0x788F-0x78C5) leaves partition 2 alone as the machine does, the resulting display start address is the games' own (line*40 words, with partition 2 wrapping the top line in at address 0), the firmware's own CSRFORM write (0xA2 <- 0x4B then one 0xA0 byte, BANK6@0x787e-0x788c) is captured and the address counter advances one 640-dot line per raster line when its line repeat is 1 (640x400) and holds each GDC line for two raster lines when it is 2 (640x200) - the step that fills a 400-line raster from a 200-GDC-line program, keyed on the slave CSRFORM and not on mode1[4] (port 0x68 bit 4), which master.lib's own 200-line routine clears after the mode set so the two registers disagree in both directions (Thexder and Touhou shapes benched) - with the armed VSYNC IRQ still firing once per frame in the 200-line mode and the address wrapping inside the 32 KiB plane, the 0xA4 display page is bit 15 of it, and the status protocol the games and the ITF wait on (bit 2 empty, bit 1 full) reads true before, during and after the transaction, with a status read in mid-stream disturbing nothing; and the partition ARITHMETIC (datapaths.md F3/F4/F5): the partition lengths count RASTER lines with the repeat phase restarting per partition (NP2kai makegrph.c:143-167, MAME upd7220.cpp:1857-1903 - fail-first against the old GDC-line boundary at raster 2*lines1), a zero-length SECOND partition takes over at the boundary and runs to the screen end (MAME's len==0 -> 0x400, real-HW-verified), and the CSRFORM line repeat covers lr = 1..32 rather than just {1,2}; and the SCROLL length word's im bit - bit 14 of EACH partition's LENGTH word - selects that partition's address step (NP2kai vram/makegrph.c:146-148 reads it per partition from para[GDC_SCROLL + gpos + 2] and doubles the pitch at 0, MAME upd7220.cpp:611/624 takes BIT(m_ra[index * 4 + 3], 6) and pc9821.cpp:103-106 shifts by im ^ 1), which is 2 x PITCH in the machine's own im = 0 state and PITCH at the 5 MHz im = 1 a game builds from BIOS work-area 0000:054D bit 2 (rec98/th01/hardware/scrollup.cpp:22-27) - pinned in both directions, one partition's bit each way, so a hard-wired step or a swap of the two partitions' bits cannot pass. It does NOT cover the graphics scanout that consumes the address, the START/STOP/SYNC/CSRW/TEXTW/VECTW commands the firmware issues on 0xA2, or a real FIFO depth. Section 8 pins a same-cycle race (race-idiom #34): a configuration write whose strobe covers the frame_end snapshot edge is DEFERRED to the next frame end and never dropped, swept across the four clk around the snapshot edge with the bus idle in between. Section 13 pins the PACKED page flip: the SCROLL start word's bit 14 is the walk's bit 15 (gfx_walk_page - NP2kai's packed arm walks LOW16(vad << 1) over the full 512 KiB with the page in that bit, vram/makegrex.c:199; MAME's flashb note names the flip register - double buffering at SAD $38fc and $fffc - pc9821.cpp:108-113) and it takes effect at the frame boundary with the rest of the SCROLL block - the uPD7220 reads the SAD at the start of the display scanning process, the machine's full-frames swap - while the planar view ({display page, walk[14:0]}) stays bit-identical across the flip. FAIL-FIRST: the old LOW15 start decode dropped the bit, so two SADs differing only in it decoded to the same walk and gfx_walk_page never set. Sections 9/10b pin NP2kai's four-partition walk (partitions 3 and 4 are the TEXTW parameter-RAM bytes 8..15, and makegrph walks 1-2-3-4-1 until the screen is full), and section 14 pins the slave SYNC's vertical graphics window (NP2kai vram/dispsync.c dispsync_renewalvertical: the walk starts at grph_vbp = slave VBP - master VBP and the graphics end at grphymax = AL + grph_vbp). Section 16 pins the PLANAR walk's step: it is the guest's slave PITCH command (0x47) byte, doubled when the partition's im bit is clear and masked to an even byte (NP2kai vram/makegrph.c:147-151) - PITCH 80 with im = 1, the 5 MHz state NP2kai's BIOS mode set writes (bios/bios18.c:483-487), steps 80 bytes, PITCH 80 with im = 0 steps 160, and PITCH 40 is the reset 40/80 again - FAIL-FIRST against the constant 40-word pitch, which stepped 40 bytes at im = 1 whatever PITCH said and showed each line's two halves side by side.

module tb_pc9821_gdc2_scroll;
  reg clk_sys = 0;
  always #5 clk_sys = ~clk_sys;
  wire clk_vid = clk_sys;
  reg pixel_ce = 1;
  reg rst_n_sys = 0, rst_n_vid = 0;
  reg io_wr = 0;
  reg io_rd = 0;
  reg [7:0] io_addr = 0, io_din = 0;
  wire [7:0] io_dout;
  wire gfx_access_page;
  wire [15:0] gfx_line_addr;
  wire gfx_walk_page;   // the PACKED walk's page bit (SCROLL start word bit 14): section 13's subject
  reg [13:0] tram_cpu_addr = 0;
  reg [7:0] tram_cpu_din = 0;
  reg tram_cpu_we = 0;
  wire [7:0] tram_cpu_dout;
  reg [12:0] cg_win_store_addr = 0;
  reg [7:0] cg_win_store_din = 0;
  reg cg_win_store_we = 0;
  reg cg_win_store_en = 0;
  wire [7:0] cg_win_store_dout;
  reg [10:0] font_ld_addr = 0;
  reg [15:0] font_ld_data = 0;
  reg font_ld_we = 0;
  wire vsync_active, disp_on;
  wire vsync_irq_arm, vsync_irq;
  wire        vsync_edge;   // the frame boundary the vblank IRQ rises on; parked for (.*)
  // The configuration-image seed (pc9821_gdc_text's cfg_* block / pc9821_iobus's memory-switch
  // strap cell): 0 = no seed, which is what this bench wants. tb_pc9821_cg_read_path drives it.
  wire [6:0] cfg_ram_mib = 7'd0;
  wire       cfg_seed_en = 1'b0;
  wire       cfg_seed_reload = 1'b0;
  // The text plane leaves the GDC as a colour and two opacity flags now, and the
  // graphics palette as a snapshot of its registers. This bench
  // drives the GDC2 command path, so they are declared only because the `.*`
  // instantiation below matches ports by name.
  wire        text_opaque, text_cell;
  wire [11:0] text_colour;
  wire [9:0]  pix_dot;
  wire        pix_h_active, pix_v_active;
  wire        gfx_mode16;
  wire [31:0] gfx_dig;
  // The analogue palette table's CPU write port (pc9821_gfx_palette's MLAB).
  wire        pal_wr_en;
  wire [3:0]  pal_wr_idx;
  wire [1:0]  pal_wr_chan;
  wire [3:0]  pal_wr_data;
  wire hs_out, vs_out, de_out;
  reg cg_record_restore = 0;

  reg [3:0] bios_set = 4'd0;   // the record's model field: 0 = Xe10 (entry 0)
  // Mirrors pc9821_system.sv: any write to port 0x64 arms the VSYNC IRQ latch.
  assign vsync_irq_arm = io_wr && (io_addr == 8'h64);
  // The IRQ is a one-cycle pulse, so poll it from a sticky flag rather than after a
  // frame wait (which would always miss it).
  reg vsync_seen = 0;
  always @(posedge clk_sys) if (vsync_irq) vsync_seen <= 1;

  wire [15:0] dbg_sad;
  wire  [7:0] dbg_pitch;
  wire        dbg_col40, dbg_disp;
  wire [15:0] dbg_wk_skips;   // the walker's skipped-walk counter

  // The character generator's window port and its glyph fetch. This bench drives
  // the GDC2 command path only, so they are tied off; they are declared because
  // pc9821_gdc_text carries them (its read path) and the `.*`
  // instantiation below matches ports by name.
  wire  [4:0]  cg_win_byte_sel = 5'd0;
  wire         cg_win_rd       = 1'b0;
  wire         cg_win_we       = 1'b0;
  wire  [7:0]  cg_win_din      = 8'h00;
  wire  [7:0]  cg_win_dout;
  wire  [18:0] font_req_addr;
  wire         font_req;
  wire         font_word_valid = 1'b0;
  wire  [31:0] font_word_data  = 32'h0;
  wire         gfx_egc_gate;
  wire         gfx_disp;   // the GDC2 display latch, which this bench does drive

  // ==== DUT ====
  wire cg_rd_hold, cg_win_byte_hold;
  // Parked: the 200-line interleave's odd-line output (pc9821_crtc's seam; this bench
  // does not check it - tb_pc9821_interleave_200 does).
  wire gfx_odd_line;
  // The ONE OSD hardware-switch field, as a LIST POSITION at ENTRY 0 - the measured
  // machine's own boot/FDD nibble (0x00). pc9821_crtc decodes and latches it and seeds its
  // TRAM tail at machine reset; it is declared so the wildcard `.*` instance below connects
  // it rather than leaving the port at zero. The base memory is hardcoded to 640 KB inside
  // pc9821_crtc.
  reg [2:0] cfg_fdd_mode = 3'd0;

  pc9821_gdc_text_dut dut (.*);

  integer i, errors = 0;
  reg [7:0] value;

  // ==== STIMULUS ====
  task automatic fail(input string message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task automatic write_io(input [7:0] portnum, input [7:0] data);
    begin
      @(negedge clk_sys);
      io_addr = portnum;
      io_din = data;
      io_wr = 1;
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

  // Drive the GDC1 PITCH parameter write (port 0x60) so its non-blocking store
  // lands at the frame_end snapshot posedge plus `offs`. offs 0 is the snapshot edge itself
  // (the copy samples the pre-write register value), -1/+1/+2 the three clk around it.
  task automatic write_param_aligned(input integer offs, input [7:0] data);
    begin
      // Sample the raster at the start of a cycle so the waits below fire in the
      // cycle the condition becomes true (the negedge that follows is that
      // cycle's own midpoint).
      @(posedge clk_sys);
      case (offs)
        -1:      wait (dut.u_crtc.vline == 9'd439 && dut.u_crtc.hdot == 10'd846);
        0:       wait (dut.u_crtc.vline == 9'd439 && dut.u_crtc.hdot == 10'd847);
        1:       wait (dut.u_crtc.vline == 9'd0   && dut.u_crtc.hdot == 10'd0);
        default: wait (dut.u_crtc.vline == 9'd0   && dut.u_crtc.hdot == 10'd1);
      endcase
      @(negedge clk_sys);
      io_addr = 8'h60; io_din = data; io_wr = 1'b1;
      @(negedge clk_sys);
      io_wr = 1'b0;
    end
  endtask

  // Run to the start of the next frame, so the frame-boundary configuration
  // snapshot has taken a write made before the call. This is also the machine's
  // own timing contract: the games write their SCROLL under a VSYNC wait.
  // The wait is on the raster's own frame_end, NOT on a frame_cnt change: frame_cnt is the
  // character blink's count and advances once per CSRFORM `timing` frames,
  // so it is no longer a frame counter.
  task automatic next_frame();
    begin
      while (dut.u_crtc.frame_end) @(negedge clk_sys);
      while (!dut.u_crtc.frame_end) @(negedge clk_sys);
      wait (dut.u_crtc.vline == 0);
    end
  endtask

  // Sample the graphics display address for decode line `ln`. The line-buffer pipeline
  // delivers that address two raster lines after the tick that latched it (pc9821_gdc_text's
  // SCANOUT_LINE_LATENCY), so decode(ln) is presented at raster line (ln - 2) mod
  // VTOTAL. The scanout owns the compensation; this samples where the raster sees it.
  task automatic check_at_line(input [8:0] ln, input [15:0] exp,
                               input [8*100-1:0] what);
    reg [9:0] r;
    begin
      r = (ln >= 9'd2) ? ({1'b0, ln} - 10'd2) : ({1'b0, ln} + 10'd438);
      wait (dut.u_crtc.vline == r[8:0]);
      @(negedge clk_sys);
      if (gfx_line_addr !== exp) begin
        $display("FAIL: %0s: decode line %0d address %04x, expected %04x",
                 what, ln, gfx_line_addr, exp);
        errors = errors + 1;
      end
    end
  endtask

  // ==== CHECKS ====
  initial begin
    repeat (4) @(posedge clk_sys);
    @(negedge clk_sys);
    rst_n_sys = 1;
    rst_n_vid = 1;

    // BCTRL on, 640x400 16-colour analogue: the production state the games and
    // the firmware run the graphics display in. 0x68 = 0x08 clears mode1[4], the
    // BIOS's 200-line flag: this is the 640x400 display mode, so the address step is
    // one GDC line per raster line. The BIOS writes the same byte on INT 18h AH=42h
    // CH=0xC0 (NP2kai bios/bios18.c:627-638).
    write_io(8'h62, 8'h0D);
    write_io(8'h6A, 8'h01);
    write_io(8'h68, 8'h08);

    // ---- 1. before any GDC2 command: start 0, one 640-dot line per line ----
    // This is the state the machine's own firmware leaves behind -- none of its
    // eight 0xA2 writes is a SCROLL (BANK4@0x5665/0x5693 START/STOP,
    // BANK4@0x5746's table sender, BANK6@0x631A/0x7912 and its mode setter,
    // BANK7@0x45DA TEXTW,
    // 0x46C0 CMD_WRITE, 0x46ED/0x48FC CSRW, 0x47D6 VECTW, 0x48EB TEXTE) -- so an
    // all-zero block must mean "the plane, from its start, 80 bytes per line"
    // and not "the same row 400 times".
    next_frame();
    check_at_line(9'd0,   16'h0000, "no SCROLL yet: first line");
    check_at_line(9'd1,   16'h0050, "no SCROLL yet: second line");
    check_at_line(9'd398, 16'h7C60, "no SCROLL yet: line 398");
    check_at_line(9'd399, 16'h7CB0, "no SCROLL yet: last line");

    // ---- 2. the status protocol ------------------------------------------
    // TH01/master.lib wait for 0xA0 bit 2 (FIFO empty) before issuing SCROLL
    // (scrollup.cpp:31, graph_scrollup.asm:67-71), and the ITF waits for the
    // same bit at BANK4@0x27EF while BANK4@0x27E4 waits for bit 1 (FIFO full) to
    // be clear. Both must read true with nothing in flight, or those loops do
    // not terminate.
    read_io(8'hA0, value);
    if (!value[2]) fail("GDC2 status bit 2 (FIFO empty) clear before any command");
    if (value[1])  fail("GDC2 status bit 1 (FIFO full) set with nothing in flight");

    // ---- 3. TH01's transaction, verbatim (scrollup.cpp:14-47) -------------
    // line_on_top = 1, so:
    //   partition 1:  dp1sta = 1 * 40 words,  dp1lin = (400 - 1) << 4
    //   partition 2:  dp2sta = 0 words,       dp2lin = 1 << 4
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h28);   // dp1sta low
    write_io(8'hA0, 8'h00);   // dp1sta high
    // A status read in the middle of the parameter stream must change nothing:
    // NP2kai drains its FIFO on a status read, which is an emulator artefact
    // rather than hardware, and real code does poll here.
    read_io(8'hA0, value);
    if (!value[2]) fail("FIFO-empty bit cleared while parameters were arriving");
    write_io(8'hA0, 8'hF0);   // dp1lin low
    write_io(8'hA0, 8'h18);   // dp1lin high
    write_io(8'hA0, 8'h00);   // dp2sta low
    write_io(8'hA0, 8'h00);   // dp2sta high
    write_io(8'hA0, 8'h10);   // dp2lin low
    write_io(8'hA0, 8'h00);   // dp2lin high

    // The parameter RAM itself. The eight bytes are partitions 1 and 2 in the
    // chip's block order (NP2kai io/gdc_cmd.h GDC_SCROLL, io/gdc_cmd.tbl row
    // 0x70), so a swap of any pair here is a swap of two fields on the screen.
    if (dut.u_gdc2.gdc2_scr[0] !== 8'h28 || dut.u_gdc2.gdc2_scr[1] !== 8'h00 ||
        dut.u_gdc2.gdc2_scr[2] !== 8'hF0 || dut.u_gdc2.gdc2_scr[3] !== 8'h18 ||
        dut.u_gdc2.gdc2_scr[4] !== 8'h00 || dut.u_gdc2.gdc2_scr[5] !== 8'h00 ||
        dut.u_gdc2.gdc2_scr[6] !== 8'h10 || dut.u_gdc2.gdc2_scr[7] !== 8'h00)
      fail("SCROLL parameter block is not TH01's eight bytes in order");

    // And the FIFO is empty again the moment the last byte is in, so the next
    // frame's pre-command wait terminates (this is what the ITF's helper at
    // BANK4@0x5746 waits on before every subsequent write).
    read_io(8'hA0, value);
    if (!value[2]) fail("FIFO-empty bit clear after the transaction completed");

    next_frame();
    // start = LOW15(word << 1) and lines = LOW14(word) >> 4: 1*40 words is byte
    // 0x50, and (400-1)<<4 is 399 lines (makegrph.c:145-148).
    if (dut.u_gdc2.v_gstart1 !== 16'h0050) fail("partition 1 start did not reach the display");
    if (dut.u_gdc2.v_glines1 !== 14'd399)  fail("partition 1 line count did not reach the display");
    if (dut.u_gdc2.v_gstart2 !== 16'h0000) fail("partition 2 start did not reach the display");
    // Partition 2's line count is not kept: only its start is read, and the switch is bounded
    // by partition 1's count and the screen height. The address checks below
    // are what prove the partition 2 entry is live.
    check_at_line(9'd0,   16'h0050, "scrolled: line 0");
    check_at_line(9'd1,   16'h00A0, "scrolled: line 1");
    check_at_line(9'd398, 16'h7CB0, "scrolled: last line of partition 1");
    // Partition 2 is what puts the top of the page back on the bottom line; with
    // only partition 1 the bottom row would repeat the row above it.
    check_at_line(9'd399, 16'h0000, "scrolled: wrapped line at the bottom");

    // ---- 4. the firmware's own SCROLL ------------------------------------
    // The graphics mode set issues 0x70 and then only FOUR parameter bytes:
    // the start word, then the length word's low and high bytes
    // (BANK6@0x788F command, 0x7894-0x78A3 start pair, 0x78A6/0x78B2 the
    // length pair, 0x78BB-0x78C5 the im bit). Partition 2 is left as it was,
    // which after a reset is zero -- so the zero length is what keeps a
    // four-byte transaction meaning "this whole screen from here", and this
    // test is the one that would fail if the block were read as "switch to
    // partition 2 at line 0".
    //   bl bit 6 set: ax = 0, length = 0x1900 -> start 0, 400 lines
    //   bl bit 6 clear: ax = 0x1F40, length = 0x0C80 -> start 0x3E80, 200 lines
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h00);   // start low  (ax = 0)
    write_io(8'hA0, 8'h00);   // start high
    write_io(8'hA0, 8'h00);   // length low
    write_io(8'hA0, 8'h19);   // length high: 400 lines, im = 0
    next_frame();
    if (dut.u_gdc2.v_glines1 !== 14'd400) fail("firmware SCROLL: partition 1 is not 400 lines");
    check_at_line(9'd0,   16'h0000, "firmware SCROLL, 400 lines: first line");
    check_at_line(9'd399, 16'h7CB0, "firmware SCROLL, 400 lines: last line");

    // The other branch of the same routine: the second half of the plane, 200
    // lines (the 200-line/31 kHz configuration). Its partition 2 is still the
    // zero the previous transaction left, so the address is partition 1's
    // start plus one row per line.
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h40);   // start = 0x1F40 words
    write_io(8'hA0, 8'h1F);
    write_io(8'hA0, 8'h80);   // length low
    write_io(8'hA0, 8'h0C);   // length high: 200 lines
    next_frame();
    if (dut.u_gdc2.v_gstart1 !== 16'h3E80) fail("firmware SCROLL: start 0x1F40 words is not byte 0x3E80");
    if (dut.u_gdc2.v_glines1 !== 14'd200) fail("firmware SCROLL: partition 1 is not 200 lines");
    check_at_line(9'd0,   16'h3E80, "firmware SCROLL, 200 lines: first line");
    check_at_line(9'd199, 16'h7CB0, "firmware SCROLL, 200 lines: last of its lines");

    // ---- 5. the address counter wraps inside the 32 KiB plane -------------
    // The GDC's own counter is 15 bits wide (LOW15), so a display that runs off
    // the top of the plane continues at the bottom of the same plane rather than
    // into the other page.
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'hFF);   // dp1sta = 0x3FFF words = byte 0x7FFE
    write_io(8'hA0, 8'h3F);
    write_io(8'hA0, 8'h00);   // dp1lin = 400 lines
    write_io(8'hA0, 8'h19);
    write_io(8'hA0, 8'h00);
    write_io(8'hA0, 8'h00);
    write_io(8'hA0, 8'h00);
    write_io(8'hA0, 8'h00);
    next_frame();
    check_at_line(9'd0, 16'h7FFE, "plane wrap: first line");
    check_at_line(9'd1, 16'h004E, "plane wrap: the line after the top of the plane");
    check_at_line(9'd2, 16'h009E, "plane wrap: and the one after that");

    // ---- 6. the display page is bit 15 of the address ---------------------
    // 0xA4 selects which 32 KiB page is scanned out (ReC98 page_show); the GDC's
    // own counter still wraps inside that page.
    write_io(8'hA4, 8'h01);
    next_frame();
    check_at_line(9'd0, 16'hFFFE, "display page 1: first line");
    check_at_line(9'd1, 16'h804E, "display page 1: line after the plane wrap");
    write_io(8'hA4, 8'h00);
    next_frame();
    check_at_line(9'd0, 16'h7FFE, "display page 0 again: first line");

    // ---- 7. the firmware's own 0xA2 traffic must not disturb SCROLL -------
    // BANK7@0x45DA writes TEXTW 0x78 to 0xA2. TEXTW's eight parameters are parameter-RAM
    // bytes 8..15 (NP2kai gdc_cmd.h GDC_TEXTW = GDC_SCROLL+8, gdc_cmd.tbl row 0x78), which
    // are partitions 3 and 4 - so they must land THERE and not in the first eight SCROLL
    // bytes, and a command byte must discard an unfulfilled parameter count (NP2kai gdc_work
    // takes the command branch before the parameter branch).
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h11);
    write_io(8'hA0, 8'h22);
    write_io(8'hA0, 8'h33);
    write_io(8'hA0, 8'h44);
    write_io(8'hA0, 8'h55);
    write_io(8'hA0, 8'h66);
    write_io(8'hA0, 8'h77);
    write_io(8'hA0, 8'h18);
    write_io(8'hA2, 8'h78);                  // TEXTW, and one parameter short of
    for (i = 0; i < 8; i = i + 1)            // a full SCROLL
      write_io(8'hA0, 8'hFF);
    if (dut.u_gdc2.gdc2_scr[0] !== 8'h11 || dut.u_gdc2.gdc2_scr[1] !== 8'h22 ||
        dut.u_gdc2.gdc2_scr[2] !== 8'h33 || dut.u_gdc2.gdc2_scr[3] !== 8'h44 ||
        dut.u_gdc2.gdc2_scr[4] !== 8'h55 || dut.u_gdc2.gdc2_scr[5] !== 8'h66 ||
        dut.u_gdc2.gdc2_scr[6] !== 8'h77 || dut.u_gdc2.gdc2_scr[7] !== 8'h18)
      fail("TEXTW's parameters reached partitions 1/2 of the SCROLL block");
    for (i = 8; i < 16; i = i + 1)
      if (dut.u_gdc2.gdc2_scr[i] !== 8'hFF)
        fail("TEXTW's parameters did not land in parameter-RAM bytes 8..15 (partitions 3/4)");
    write_io(8'hA0, 8'hFF);                  // and a parameter with no command at
    write_io(8'hA0, 8'hFF);                  // all is dropped too
    if (dut.u_gdc2.gdc2_scr[0] !== 8'h11 || dut.u_gdc2.gdc2_scr[7] !== 8'h18)
      fail("a parameter byte outside any command reached the SCROLL block");

    // A new command discards an unfulfilled count: one parameter of a SCROLL,
    // then TEXTW, then eight more bytes -- only the first byte may land.
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h99);
    write_io(8'hA2, 8'h78);
    for (i = 0; i < 8; i = i + 1)
      write_io(8'hA0, 8'hEE);
    if (dut.u_gdc2.gdc2_scr[0] !== 8'h99)
      fail("the accepted SCROLL parameter did not land in block byte 0");
    if (dut.u_gdc2.gdc2_scr[1] !== 8'h22 || dut.u_gdc2.gdc2_scr[2] !== 8'h33 ||
        dut.u_gdc2.gdc2_scr[3] !== 8'h44 || dut.u_gdc2.gdc2_scr[4] !== 8'h55 ||
        dut.u_gdc2.gdc2_scr[5] !== 8'h66 || dut.u_gdc2.gdc2_scr[6] !== 8'h77 ||
        dut.u_gdc2.gdc2_scr[7] !== 8'h18)
      fail("an unfulfilled SCROLL count survived a new command byte");

    // ---- 8. the slave CSRFORM line repeat selects the display's line step ---
    // The display maps one GDC line onto every `lr` raster lines,
    // lr = (slave CSRFORM & 0x1f) + 1: lr = 1 is 640x400 (one GDC line per raster line),
    // lr = 2 is the 640x200 display (each GDC line held twice, so its 200 GDC lines fill the
    // 400-line raster). CSRFORM is the ONE byte after 0xA2 <- 0x4B (the firmware's own
    // transaction, BANK6@0x787e-0x788c): 0 for 640x400, 1 for the 200-line display.
    // mode1[4] (port 0x68 bit 4) is NOT the key: master.lib's graph_200line clears it
    // (out 68h,8) AFTER the firmware sets CSRFORM, so the two disagree for the games.
    // NP2kai vram/makegrph.c:362 and QEMU pc98-vga.c:4474 read the step from CSRFORM; the
    // display latches the captured byte at the frame boundary, so a frame passes after a
    // change.

    // A 400-line SCROLL, partition 2 left at zero: the line step is the only variable.
    // mode1[4] starts clear (0x68 <- 0x08, section 1); it is NOT the step key, so it stays
    // out of the way of the CSRFORM cases below.
    write_io(8'h68, 8'h08);
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h00);   // start 0
    write_io(8'hA0, 8'h00);
    write_io(8'hA0, 8'h00);   // 400 lines: partition 2 never takes over here
    write_io(8'hA0, 8'h19);
    write_io(8'hA0, 8'h00);
    write_io(8'hA0, 8'h00);
    write_io(8'hA0, 8'h00);
    write_io(8'hA0, 8'h00);

    // (1) firmware CSRFORM = 1 (200-line): the step doubles.
    write_io(8'hA2, 8'h4B);
    write_io(8'hA0, 8'h01);
    if (dut.u_gdc2.gdc2_lr !== 5'd1) fail("the 0xA2<-0x4B 0xA0 byte was not captured");
    next_frame();
    if (dut.u_gdc2.v_lr2 !== 5'd1) fail("CSRFORM=1 did not reach the display latch");
    check_at_line(9'd1, 16'h0000, "CSRFORM=1: line 1 is GDC line 0, the line held twice");
    check_at_line(9'd2, 16'h0050, "CSRFORM=1: line 2 is GDC line 1");
    // Raster line 399 is GDC line 199, so 199*80 = 0x3E30 is the last address of a
    // 200-GDC-line program rather than the wrap a 1:1 step reaches - the top-half bug.
    check_at_line(9'd399, 16'h3E30, "CSRFORM=1: the last raster line is GDC line 199");

    // (2) CSRFORM = 0 (640x400): one GDC line per raster line.
    write_io(8'hA2, 8'h4B);
    write_io(8'hA0, 8'h00);
    next_frame();
    if (dut.u_gdc2.v_lr2 !== 5'd0) fail("CSRFORM=0 did not reach the display latch");
    check_at_line(9'd1, 16'h0050, "CSRFORM=0: line 1 is GDC line 1");
    check_at_line(9'd399, 16'h7CB0, "CSRFORM=0: line 399 is GDC line 399");

    // (3) the Thexder shape: master.lib graph_200line clears mode1[4] (out 68h,8) and the
    // firmware's mode set raised CSRFORM to 1. The step must follow CSRFORM and double.
    write_io(8'h68, 8'h08);
    write_io(8'hA2, 8'h4B);
    write_io(8'hA0, 8'h01);
    next_frame();
    check_at_line(9'd2, 16'h0050, "Thexder shape (mode1[4]=0, CSRFORM=1): line 2 is GDC line 1");
    check_at_line(9'd399, 16'h3E30, "Thexder shape: the last raster line is GDC line 199");

    // (4) the Touhou shape: mode1[4] set (0x68 <- 0x09) but CSRFORM = 0. The step must
    // stay 1:1 - the key is CSRFORM, not mode1[4], in BOTH directions.
    write_io(8'h68, 8'h09);
    write_io(8'hA2, 8'h4B);
    write_io(8'hA0, 8'h00);
    next_frame();
    check_at_line(9'd1, 16'h0050, "Touhou shape (mode1[4]=1, CSRFORM=0): line 1 is GDC line 1");
    check_at_line(9'd399, 16'h7CB0, "Touhou shape: line 399 is GDC line 399");

    // (5) the firmware's whole setter shape (BANK6@0x7847): the 0x68 mode write, CSRFORM = 1,
    // then the four-byte SCROLL {start 0, 400 lines}. The capture and the SCROLL block are
    // separate receivers, and the step doubles.
    write_io(8'h68, 8'h08);
    write_io(8'hA2, 8'h4B);
    write_io(8'hA0, 8'h01);
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h00);   // start low
    write_io(8'hA0, 8'h00);   // start high
    write_io(8'hA0, 8'h00);   // length low
    write_io(8'hA0, 8'h19);   // length high: 400 lines
    next_frame();
    if (dut.u_gdc2.v_gstart1 !== 16'h0000) fail("setter shape: partition 1 start is not 0");
    if (dut.u_gdc2.v_glines1 !== 14'd400)  fail("setter shape: partition 1 is not 400 lines");
    check_at_line(9'd2, 16'h0050, "setter shape: line 2 is GDC line 1");
    check_at_line(9'd399, 16'h3E30, "setter shape: the last raster line is GDC line 199");

    // The vertical timing does NOT move with the display mode: the 200-line picture is
    // doubled INSIDE the same 848x440 raster, so the frame is still 440 lines and the
    // armed VSYNC IRQ (INT 0Ah, port 0x64) still fires once per frame - which is what a
    // 2.5 MHz game's vsync wait depends on. The raster constants are the machine's own
    // (the machine's probe results: the GDC clock does not change the display mode).
    vsync_seen = 0;
    write_io(8'h64, 8'h00);   // arm the one-shot
    next_frame();
    if (!vsync_seen) fail("the armed VSYNC IRQ did not fire in the 200-line mode");

    // Back to 640x400 (CSRFORM = 0): 1:1 again, so the last word is not the doubled step.
    write_io(8'hA2, 8'h4B);
    write_io(8'hA0, 8'h00);
    next_frame();
    check_at_line(9'd1, 16'h0050, "back to CSRFORM=0: line 1 is GDC line 1 again");

    // ---- 9. F3: SCROLL lengths count RASTER lines, the repeat phase restarts ----
    // The 200-line two-partition scroll (the TH01 pattern at 200 lines): lr = 2,
    // partition 1 = {start word 0x0000, 100 lines}, partition 2 = {start word
    // 0x1000 (byte 0x2000), 100 lines}. NP2kai's grphput walk (makegrph.c:143-167)
    // decrements the length per RASTER line and re-seeds the lr phase at each
    // partition, so: rasters 0..99 cover partition 1's 50 GDC lines doubled,
    // rasters 100..199 cover partition 2's 50 from ITS OWN phase start. The old
    // decode counted the boundary in GDC lines (it fired at raster 200) and kept
    // one global phase across the switch - fail-first here at rasters 99/100/101.
    write_io(8'hA2, 8'h4B);
    write_io(8'hA0, 8'h01);                    // lr-1 = 1 -> lr = 2
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00);   // start1 word 0x0000
    write_io(8'hA0, 8'h40); write_io(8'hA0, 8'h06);   // length 100 << 4
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h10);   // start2 word 0x1000
    write_io(8'hA0, 8'h40); write_io(8'hA0, 8'h06);   // length 100 << 4
    write_io(8'hA2, 8'h78);                           // TEXTW = partitions 3 and 4
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h20);   // start3 word 0x2000
    write_io(8'hA0, 8'h20); write_io(8'hA0, 8'h03);   // length 50 << 4
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h30);   // start4 word 0x3000
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00);   // length 0
    next_frame();
    check_at_line(9'd0,   16'h0000, "F3 raster 0: partition 1, GDC line 0");
    check_at_line(9'd1,   16'h0000, "F3 raster 1: partition 1, GDC line 0 held twice");
    check_at_line(9'd2,   16'h0050, "F3 raster 2: partition 1, GDC line 1");
    check_at_line(9'd98,  16'h0F50, "F3 raster 98: partition 1's GDC line 49");
    check_at_line(9'd99,  16'h0F50, "F3 raster 99: partition 1's last raster line");
    check_at_line(9'd100, 16'h2000, "F3 raster 100: partition 2 takes over AT the raster boundary");
    check_at_line(9'd101, 16'h2000, "F3 raster 101: partition 2's GDC line 0 held twice");
    check_at_line(9'd102, 16'h2050, "F3 raster 102: partition 2's phase restarts at its own start");
    check_at_line(9'd198, 16'h2F50, "F3 raster 198: partition 2's GDC line 49");
    check_at_line(9'd199, 16'h2F50, "F3 raster 199: partition 2's last raster line");
    check_at_line(9'd200, 16'h4000, "F3 raster 200: partition 3 takes over after partition 2's length");
    check_at_line(9'd201, 16'h4000, "F3 raster 201: partition 3's GDC line 0 held twice");
    check_at_line(9'd202, 16'h4050, "F3 raster 202: partition 3 advances from its own phase");
    check_at_line(9'd249, 16'h4780, "F3 raster 249: partition 3's last raster line");
    check_at_line(9'd250, 16'h6000, "F3 raster 250: partition 4 takes over");
    check_at_line(9'd252, 16'h6050, "F3 raster 252: partition 4 advances");
    check_at_line(9'd399, 16'h7720, "F3 raster 399: the never-expiring partition 4 runs to the screen end");
    // Past the two lengths NP2kai's makegrph goes on to partition 3 and then 4 (its
    // `while(1)` over gpos 0/4/8/12, makegrph.c:364-381) - programmed here through TEXTW
    // 0x78, i.e. parameter-RAM bytes 8..15: partition 3 = {start word 0x2000 (byte 0x4000),
    // 50 lines}, partition 4 = {start word 0x3000 (byte 0x6000), 0 = never expires}. The
    // expected addresses are NP2kai makegrph's walk of this block (lr = 2).
    // The pre-fix decode kept partition 2 running to the screen end (0x2FA0 at raster 200,
    // after MAME's "unverified" note); NP2kai is the primary reference, so that divergence is
    // gone - fail-first at raster 200.

    // ---- 10. F4: a zero-length SECOND partition takes over and runs to the end ----
    // Only lines1 == 0 means "never switch". With {200 lines} + {0} the switch
    // happens at raster 200 and the zero-length partition 2 runs to the screen end
    // with start2 (MAME upd7220.cpp:1866-1868 len==0 -> 0x400, "proven to be
    // correct via real HW verification" (madoum1); NP2kai's remain-- on 0 wraps
    // and the partition never expires). The old decode treated lines2 == 0 as
    // "never switch" too, leaving partition 1 across the whole screen - fail-first
    // at raster 200.
    write_io(8'hA2, 8'h4B);
    write_io(8'hA0, 8'h00);                          // lr = 1 (the 400-line table)
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00);  // start1 word 0x0000
    write_io(8'hA0, 8'h80); write_io(8'hA0, 8'h0C);  // length 200 << 4
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h10);  // start2 word 0x1000 -> byte 0x2000
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00);  // length 0
    next_frame();
    check_at_line(9'd0,   16'h0000, "F4 raster 0: partition 1");
    check_at_line(9'd199, 16'h3E30, "F4 raster 199: partition 1's last line");
    check_at_line(9'd200, 16'h2000, "F4 raster 200: the zero-length partition 2 takes over");
    check_at_line(9'd201, 16'h2050, "F4 raster 201: partition 2 advances from its start");
    check_at_line(9'd399, 16'h5E30, "F4 raster 399: partition 2 runs to the screen end");

    // ---- 10b. four partitions that end before the screen does: the walk returns to 1 ----
    // NP2kai's makegrph loops `while(1)` over partitions 1, 2, 3, 4 until the display is
    // full, so four 50/100-line partitions summing to 300 lines show partition 1 again from
    // raster 300 (expected values: np2_makegrph.py, lr = 1). The pre-fix decode had no
    // partitions 3/4 at all and kept partition 2 to the end.
    write_io(8'hA2, 8'h4B);
    write_io(8'hA0, 8'h00);                          // lr = 1
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00);  // start1 word 0x0000
    write_io(8'hA0, 8'h40); write_io(8'hA0, 8'h06);  // length 100 << 4
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h10);  // start2 word 0x1000
    write_io(8'hA0, 8'h40); write_io(8'hA0, 8'h06);  // length 100 << 4
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h20);  // start3 word 0x2000 (SCROLL's 16 bytes
    write_io(8'hA0, 8'h20); write_io(8'hA0, 8'h03);  // run on into partitions 3/4) length 50
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h30);  // start4 word 0x3000
    write_io(8'hA0, 8'h20); write_io(8'hA0, 8'h03);  // length 50
    next_frame();
    check_at_line(9'd99,  16'h1EF0, "wrap: partition 1's last line");
    check_at_line(9'd100, 16'h2000, "wrap: partition 2");
    check_at_line(9'd200, 16'h4000, "wrap: partition 3");
    check_at_line(9'd250, 16'h6000, "wrap: partition 4");
    check_at_line(9'd299, 16'h6F50, "wrap: partition 4's last line");
    check_at_line(9'd300, 16'h0000, "wrap: partition 1 again after partition 4 (makegrph's while(1))");
    check_at_line(9'd301, 16'h0050, "wrap: partition 1 advances again");
    check_at_line(9'd399, 16'h1EF0, "wrap: partition 1's second pass at the screen end");
    // the 16-byte SCROLL left partitions 3/4 programmed; clear them for the sections below
    write_io(8'hA2, 8'h78);
    for (i = 0; i < 8; i = i + 1) write_io(8'hA0, 8'h00);

    // ---- 11. F5: the CSRFORM line repeat covers lr = 1..32 (CSRFORM[4:0]+1) ----
    // NP2kai vram/makegrph.c:362 (mg.lr = (para & 0x1f) + 1, mul countdown) and
    // MAME upd7220.cpp:1874 (y / m_lr): the GDC line is floor(raster_within_
    // partition / lr). The old decode modelled only lr in {1,2}; lr-1 = 2..31
    // silently behaved as 1 (a stride on every raster line) - fail-first at
    // raster 1.
    write_io(8'hA2, 8'h4B);
    write_io(8'hA0, 8'h02);                          // lr-1 = 2 -> lr = 3
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00);  // start1 word 0x0000
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h19);  // length 400 << 4
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00);
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00);
    next_frame();
    check_at_line(9'd0,   16'h0000, "F5 lr=3 raster 0: GDC line 0");
    check_at_line(9'd1,   16'h0000, "F5 lr=3 raster 1: GDC line 0");
    check_at_line(9'd2,   16'h0000, "F5 lr=3 raster 2: GDC line 0");
    check_at_line(9'd3,   16'h0050, "F5 lr=3 raster 3: GDC line 1");
    check_at_line(9'd5,   16'h0050, "F5 lr=3 raster 5: GDC line 1 held three times");
    check_at_line(9'd396, 16'h2940, "F5 lr=3 raster 396: GDC line 132");
    check_at_line(9'd399, 16'h2990, "F5 lr=3 raster 399: GDC line 133");
    write_io(8'hA2, 8'h4B);
    write_io(8'hA0, 8'h1F);                          // lr-1 = 31 -> lr = 32
    next_frame();
    check_at_line(9'd0,   16'h0000, "F5 lr=32 raster 0: GDC line 0");
    check_at_line(9'd31,  16'h0000, "F5 lr=32 raster 31: GDC line 0 held 32 times");
    check_at_line(9'd32,  16'h0050, "F5 lr=32 raster 32: GDC line 1");
    check_at_line(9'd399, 16'h03C0, "F5 lr=32 raster 399: GDC line 12");
    // ---- 12. the SCROLL length word's im bit (bit 14) selects the address step ----
    // NP2kai vram/makegrph.c:146-148 (`if (!(remain & (1 << 14))) pitch <<= 1;`) and MAME
    // pc9821.cpp:103-106 (`pitch << (im ^ 1)`, im = upd7220.cpp:611/624 BIT(m_ra[index *
    // 4 + 3], 6)) both make bit 14 of EACH partition's LENGTH word the display-address
    // increment select: im = 0 doubles the pitch, im = 1 leaves it. Every section above is
    // the machine's own state - work-area 0000:054D bit 2 clear, i.e. the 2.5 MHz GDC, so
    // im = 0 and the step is 2 x PITCH. This section is the 5 MHz machine, which is what
    // the games build from that same byte: TH01 writes `im = (1 << 6)` into BOTH
    // partitions' length high byte (rec98/th01/hardware/scrollup.cpp:22-27).
    // The two cases also take the two partitions' bits in OPPOSITE directions, so a decode
    // that reads one word's bit twice (or hard-wires the step) cannot pass both.
    // FAIL-FIRST: the old decode hard-wired 2 x PITCH, so every im = 1 check below reads
    // the doubled address (raster 1 at 0x50 instead of 0x28, and so on).
    write_io(8'hA2, 8'h4B);
    write_io(8'hA0, 8'h00);                          // lr = 1
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00);  // start1 = 0
    write_io(8'hA0, 8'h80); write_io(8'hA0, 8'h4C);  // length1 = 200 << 4, im = 1 (bit 14)
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h10);  // start2 = word 0x1000 -> byte 0x2000
    write_io(8'hA0, 8'h80); write_io(8'hA0, 8'h0C);  // length2 = 200 << 4, im = 0
    next_frame();
    check_at_line(9'd0,   16'h0000, "im = 1: raster 0");
    check_at_line(9'd1,   16'h0028, "im = 1: one PITCH (40 bytes) per line, not 2 x PITCH");
    check_at_line(9'd199, 16'h1F18, "im = 1: partition 1's 199th line (199 x 40)");
    check_at_line(9'd200, 16'h2000, "im = 0 partition 2 takes over at its own start");
    check_at_line(9'd201, 16'h2050, "im = 0 partition 2 steps 2 x PITCH from its start");
    check_at_line(9'd399, 16'h5E30, "im = 0 partition 2 runs to the screen end at 2 x PITCH");

    // The mirrored case: partition 1 im = 0, partition 2 im = 1 (a 5 MHz machine's page
    // wrap is the shape TH01 actually builds - both words carry im - so this half pins the
    // per-partition read, which the symmetric case alone could not tell from one global bit).
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00);  // start1 = 0
    write_io(8'hA0, 8'h80); write_io(8'hA0, 8'h0C);  // length1 = 200 << 4, im = 0
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h10);  // start2 = byte 0x2000
    write_io(8'hA0, 8'h80); write_io(8'hA0, 8'h4C);  // length2 = 200 << 4, im = 1
    next_frame();
    check_at_line(9'd1,   16'h0050, "im = 0 partition 1 still steps 2 x PITCH");
    check_at_line(9'd199, 16'h3E30, "im = 0 partition 1's 199th line (199 x 80)");
    check_at_line(9'd200, 16'h2000, "im = 1 partition 2 takes over at its own start");
    check_at_line(9'd201, 16'h2028, "im = 1 partition 2 steps one PITCH per line");
    check_at_line(9'd399, 16'h3F18, "im = 1 partition 2 runs to the screen end at one PITCH");

    // ---- 8. race-idiom #34: the frame-boundary configuration
    // snapshot DEFERS a write it raced, it does not drop it. ----
    // The frame_end snapshot copies the configuration registers with
    // non-blocking assignments, so a write whose strobe covers the frame_end
    // posedge is not in that copy. The old cfg_dirty/ack handshake then cleared
    // the flag when that copy acknowledged and the write stayed invisible until
    // some later write re-dirtied the flag (the window pc9821_gdc2's comment
    // admits). The epoch-qualified ack keeps the flag and re-copies at the next
    // frame end. The PITCH command 0x47 is a ONE-parameter command, so its
    // parameter byte is the last bus activity; sweep its alignment across the
    // four clk around the snapshot edge, hold the bus idle, and require the new
    // pitch at the display latch by the second frame end every time.
    begin : f1
      integer k;
      reg [7:0] v;
      for (k = -1; k <= 2; k = k + 1) begin
        v = 8'h2E + (k + 1) * 2;      // even values: the latch keeps {d[7:1],0}
        write_io(8'h62, 8'h47);       // GDC1 PITCH, exactly one parameter
        write_param_aligned(k, v);
        next_frame();                 // the two frame ends from the write
        next_frame();
        @(negedge clk_sys);
        if (dbg_pitch !== v)
          fail($sformatf("F1 align %0d: v_pitch is %02h two frame ends later, want %02h - the snapshot dropped the write",
                         k, dbg_pitch, v));
      end
    end

    // ---- 13. the PACKED page flip: the SCROLL start word's bit 14 ----
    // The 256-colour games double-buffer through the GDC2 SCROLL start word's bit 14:
    // MAME's flashb note names the register ("does double buffering at SAD $38fc and
    // $fffc", pc9821.cpp:108-113) and its walk keeps word bit 14 as the 512 KiB page
    // bit (`((base_address << 1) ... & 0xffff) << 3`, pc9821.cpp:112); NP2kai's packed
    // arm walks `LOW16(vad << 1)` over the same 512 KiB (vram/makegrex.c:199). The
    // uPD7220 reads the SAD "at the start of the display scanning process", so the flip
    // lands at the FRAME BOUNDARY with the rest of the SCROLL block - the machine's
    // full-frames swap (the real Xe10 under DOOM). FAIL-FIRST: the old start decode
    // was LOW15 (`{scr[1][5:0], scr[0], 1'b0}`), so two SADs differing only in bit 14
    // decoded to the SAME walk and the display never moved - v_gstart1 is 0x0050 in
    // both rows below and gfx_walk_page never sets.
    write_io(8'hA2, 8'h4B);
    write_io(8'hA0, 8'h00);                          // lr = 1
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h28); write_io(8'hA0, 8'h00);  // start1 = word 0x0028 (bit 14 clear)
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h19);  // length1 = 400 << 4
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00);  // partition 2 at zero
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00);
    next_frame();
    if (dut.u_gdc2.v_gstart1 !== 16'h0050) fail("walk page: start word 0x0028 is walk 0x0050");
    if (gfx_walk_page !== 1'b0) fail("walk page set with start word bit 14 clear");
    check_at_line(9'd1,   16'h00A0, "walk page 0: line 1 (0x50 + 1 x 0x50)");
    check_at_line(9'd399, 16'h7D00, "walk page 0: line 399 (0x50 + 399 x 0x50)");
    // The flip: start word 0x4028 - bit 14 set, the low 14 bits unchanged. The walk
    // becomes 0x8050 and the page bit must show only at the frame boundary: the write
    // is mid-frame (vline 200), so the current frame keeps the old page to its last
    // decode line (439 - the +2 pipeline means rows 0/1 of the NEXT frame are decoded
    // at vlines 438/439 and belong to it), and the new page is there from line 0 on.
    wait (dut.u_crtc.vline == 9'd200);
    @(negedge clk_sys);
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h28); write_io(8'hA0, 8'h40);  // start1 = word 0x4028 (bit 14 set)
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h19);  // length1 unchanged
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00);
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00);
    if (gfx_walk_page !== 1'b0) fail("walk page flipped at the write instead of the frame boundary");
    wait (dut.u_crtc.vline == 9'd250);
    @(negedge clk_sys);
    if (gfx_walk_page !== 1'b0) fail("walk page moved mid-frame: the current frame must keep the old page");
    wait (dut.u_crtc.vline == 9'd437);
    @(negedge clk_sys);
    if (gfx_walk_page !== 1'b0) fail("walk page moved before the frame boundary (decode line 439)");
    next_frame();
    if (dut.u_gdc2.v_gstart1 !== 16'h8050) fail("walk page: start word 0x4028 is walk 0x8050");
    if (gfx_walk_page !== 1'b1) fail("walk page did not reach the scanout at the frame boundary");
    // The planar view ({display page, walk[14:0]}) is bit-identical across the flip -
    // the page bit is the PACKED scanout's alone (tb_pc9821_pegc_scanout pins its use).
    check_at_line(9'd1,   16'h00A0, "walk page 1: the planar view is unchanged");
    check_at_line(9'd399, 16'h7D00, "walk page 1: and so at line 399");

    // ---- 14. the slave SYNC's vertical window (NP2kai dispsync_renewalvertical) ----
    // NP2kai places the graphics walk at screen line grph_vbp = slave VBP - master VBP (0 if
    // the master's is larger) and ends it at grphymax = ((AL - 1) & 0x3ff) + 1 + grph_vbp,
    // the lines outside black (vram/dispsync.c; makegrph.c:363 `mg.liney = dsync.grph_vbp`,
    // :169 `if (mg.liney >= dsync.grphymax)`). Slave SYNC with AL = 280 and VBP = 57 against the
    // master's power-on VBP 25: window rows 32..311 (np2_makegrph.window(0x65, 0x18, 0xE5) =
    // (32, 312)), the walk's line 0 at raster 32 (np2_makegrph.walk(..., ymax=312, vbp=32)).
    // FAIL-FIRST: the pre-fix core consumed the slave's SYNC bytes and drove nothing from them,
    // so graphics showed on every line and the walk started at raster 0.
    if (dut.u_crtc.o_vbp !== 6'd25) fail("window: the master's displayed VBP is not the power-on 25");
    write_io(8'hA2, 8'h4B); write_io(8'hA0, 8'h00);    // lr = 1
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00);    // partition 1 = {0, 400 lines}
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h19);
    write_io(8'hA2, 8'h0F);                            // slave SYNC: the firmware's block with
    write_io(8'hA0, 8'h06); write_io(8'hA0, 8'h26);    // AL 280 (0x118) and VBP 57
    write_io(8'hA0, 8'h03); write_io(8'hA0, 8'h11);
    write_io(8'hA0, 8'h83); write_io(8'hA0, 8'h07);
    write_io(8'hA0, 8'h18); write_io(8'hA0, 8'hE5);
    next_frame();
    next_frame();
    check_at_line(9'd32,  16'h0000, "window: the walk's line 0 at raster grph_vbp = 32");
    check_at_line(9'd33,  16'h0050, "window: line 1 at raster 33");
    check_at_line(9'd100, 16'h1540, "window: raster 100 is walk line 68");
    check_at_line(9'd311, 16'h5730, "window: the window's last line, walk line 279");
    begin : winchk
      integer rr;
      for (rr = 0; rr < 400; rr = rr + 1) begin
        wait (dut.u_crtc.vline == rr[9:0]);
        @(negedge clk_sys);
        if (dut.u_gdc2.gfx_win_off !== ((rr < 32) || (rr >= 312)))
          fail($sformatf("window: raster %0d graphics %s, expected %s", rr,
                         dut.u_gdc2.gfx_win_off ? "off" : "on",
                         ((rr < 32) || (rr >= 312)) ? "off" : "on"));
      end
    end
    // restore the firmware's slave block (AL 400, VBP 25): the whole display again
    write_io(8'hA2, 8'h0F);
    write_io(8'hA0, 8'h06); write_io(8'hA0, 8'h26);
    write_io(8'hA0, 8'h03); write_io(8'hA0, 8'h11);
    write_io(8'hA0, 8'h83); write_io(8'hA0, 8'h07);
    write_io(8'hA0, 8'h90); write_io(8'hA0, 8'h65);
    next_frame();
    next_frame();
    check_at_line(9'd0, 16'h0000, "window restored: the walk's line 0 at raster 0");
    check_at_line(9'd1, 16'h0050, "window restored: line 1 at raster 1");
    begin : winchk2
      wait (dut.u_crtc.vline == 10'd5); @(negedge clk_sys);
      if (dut.u_gdc2.gfx_win_off !== 1'b0) fail("window restored: raster 5 still off");
      wait (dut.u_crtc.vline == 10'd399); @(negedge clk_sys);
      if (dut.u_gdc2.gfx_win_off !== 1'b0) fail("window restored: raster 399 still off");
    end

    // ---- 15. the PACKED (256-colour) walk: NP2kai vram/makegrex.c makegrphex ----
    // Three differences from the planar walk, all NP2kai's (MAME's packed draw agrees on
    // the first): grphput_all steps `vad = LOW16(vad + mg.pitch)` on EVERY raster line and
    // never reads the CSRFORM line repeat; makegrphex loops `grphput(&mg, 0)` /
    // `grphput(&mg, 4)` only, so partition 2 returns to partition 1 (the TEXTW slots are
    // not display partitions); and the walk runs inside the slave SYNC's window
    // (`mg.liney = dsync.grph_vbp` ... `if (mg.liney >= dsync.grphymax)`), the rest black.
    // FAIL-FIRST (rtlrev-video): the pre-fix walk repeated each line lr times, walked into
    // partition 3, and pc9821_system lifted the window in 256-colour mode (the window rows
    // below were verified to fail with that exception reinstated as gfx_grph_on's term).
    write_io(8'h6A, 8'h07); write_io(8'h6A, 8'h21); write_io(8'h6A, 8'h06);   // PEGC select
    write_io(8'hA2, 8'h4B); write_io(8'hA0, 8'h01);    // lr = 2 (a 200-line leftover)
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00);    // partition 1: start 0, 100 lines
    write_io(8'hA0, 8'h40); write_io(8'hA0, 8'h06);
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h10);    // partition 2: start word 0x1000, 100 lines
    write_io(8'hA0, 8'h40); write_io(8'hA0, 8'h06);
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h30);    // partition 3 (TEXTW): word 0x3000
    write_io(8'hA0, 8'h40); write_io(8'hA0, 8'h06);
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h38);    // partition 4 (TEXTW): word 0x3800
    write_io(8'hA0, 8'h40); write_io(8'hA0, 8'h06);
    next_frame();
    next_frame();
    check_at_line(9'd0,   16'h0000, "packed: line 0 is partition 1's start");
    check_at_line(9'd1,   16'h0050, "packed: line 1 steps one pitch (no CSRFORM repeat)");
    check_at_line(9'd99,  16'h1EF0, "packed: line 99 is partition 1's last");
    check_at_line(9'd100, 16'h2000, "packed: line 100 is partition 2's start");
    check_at_line(9'd200, 16'h0000, "packed: line 200 returns to partition 1, not 3");
    check_at_line(9'd201, 16'h0050, "packed: line 201 is partition 1's second line");
    // The window: slave SYNC with AL = 200 (VBP 25, the master's) - graphics on 0..199 only.
    write_io(8'hA2, 8'h0F);
    write_io(8'hA0, 8'h06); write_io(8'hA0, 8'h26);
    write_io(8'hA0, 8'h03); write_io(8'hA0, 8'h11);
    write_io(8'hA0, 8'h83); write_io(8'hA0, 8'h07);
    write_io(8'hA0, 8'hC8); write_io(8'hA0, 8'h64);
    next_frame();
    next_frame();
    begin : pkwin
      wait (dut.u_crtc.vline == 10'd10);  @(negedge clk_sys);
      if (dut.gfx_grph_on !== 1'b1) fail("packed window: raster 10 graphics off");
      wait (dut.u_crtc.vline == 10'd199); @(negedge clk_sys);
      if (dut.gfx_grph_on !== 1'b1) fail("packed window: raster 199 graphics off");
      wait (dut.u_crtc.vline == 10'd200); @(negedge clk_sys);
      if (dut.gfx_grph_on !== 1'b0) fail("packed window: raster 200 shows graphics past grphymax");
      wait (dut.u_crtc.vline == 10'd399); @(negedge clk_sys);
      if (dut.gfx_grph_on !== 1'b0) fail("packed window: raster 399 shows graphics past grphymax");
    end
    // restore: AL 400, lr 1, the planar view
    write_io(8'hA2, 8'h0F);
    write_io(8'hA0, 8'h06); write_io(8'hA0, 8'h26);
    write_io(8'hA0, 8'h03); write_io(8'hA0, 8'h11);
    write_io(8'hA0, 8'h83); write_io(8'hA0, 8'h07);
    write_io(8'hA0, 8'h90); write_io(8'hA0, 8'h65);
    write_io(8'hA2, 8'h4B); write_io(8'hA0, 8'h00);
    write_io(8'h6A, 8'h07); write_io(8'h6A, 8'h20); write_io(8'h6A, 8'h06);

    // ---- 16. the PLANAR walk's step is the guest's PITCH, selected by im ----
    // NP2kai vram/makegrph.c:147-151: `pitch = gdc.s.para[GDC_PITCH]; if (!(remain & (1 <<
    // 14))) pitch <<= 1; pitch &= 0xfe;` - the slave PITCH command's byte (0x47, one
    // parameter), doubled when the partition's im bit is clear. NP2kai's BIOS 5 MHz mode set
    // writes PITCH 80 AND the im bit (bios/bios18.c:483-487 `gdc.s.para[GDC_PITCH] = 80;` ..
    // `gdc.s.para[GDC_SCROLL+3] = 0x40;`), so that state steps 80 bytes, one 640-dot line.
    // FAIL-FIRST: the constant 40-word pitch stepped 40 bytes at im = 1 whatever PITCH said
    // (raster 1 at 0x0028 instead of 0x0050), showing each line's two halves side by side.
    write_io(8'hA2, 8'h47); write_io(8'hA0, 8'h50);  // slave PITCH = 80
    write_io(8'hA2, 8'h70);
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00);  // start1 = 0
    write_io(8'hA0, 8'h80); write_io(8'hA0, 8'h4C);  // length1 = 200 << 4, im = 1
    write_io(8'hA0, 8'h00); write_io(8'hA0, 8'h00);  // start2 = 0
    write_io(8'hA0, 8'h80); write_io(8'hA0, 8'h0C);  // length2 = 200 << 4, im = 0
    next_frame();
    next_frame();
    check_at_line(9'd0,   16'h0000, "PITCH 80 im = 1: raster 0");
    check_at_line(9'd1,   16'h0050, "PITCH 80 im = 1: one PITCH (80 bytes) per line, not the reset 40");
    check_at_line(9'd199, 16'h3E30, "PITCH 80 im = 1: partition 1's 199th line (199 x 80)");
    check_at_line(9'd200, 16'h0000, "PITCH 80 im = 0: partition 2 at its start");
    check_at_line(9'd201, 16'h00A0, "PITCH 80 im = 0: 2 x PITCH (160 bytes) per line");
    check_at_line(9'd399, 16'h7C60, "PITCH 80 im = 0: partition 2's 199th line (199 x 160)");
    // An odd PITCH is masked to an even byte (`pitch &= 0xfe`) at im = 1.
    write_io(8'hA2, 8'h47); write_io(8'hA0, 8'h51);  // slave PITCH = 81
    next_frame();
    next_frame();
    check_at_line(9'd1,   16'h0050, "PITCH 81 im = 1: masked to 80 bytes");
    check_at_line(9'd201, 16'h00A2, "PITCH 81 im = 0: 2 x 81 = 162 bytes");
    // Back to the reset PITCH 40: the step follows the register, not a latch of the 80.
    write_io(8'hA2, 8'h47); write_io(8'hA0, 8'h28);
    next_frame();
    next_frame();
    check_at_line(9'd1,   16'h0028, "PITCH 40 im = 1: 40 bytes again");
    check_at_line(9'd201, 16'h0050, "PITCH 40 im = 0: 80 bytes again");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GDC2_SCROLL: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_GDC2_SCROLL: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog. A frame here is 848 x 440 = 373,120 dots, so the
  // frames this bench walks through (sections 1-12 plus section 8's four
  // two-frame alignment sweeps) were ~17 M cycles = 170 ms of simulated time; with
  // sections 13-16 the bench finishes at ~270 ms, and 400 ms leaves ~1.5x headroom.
  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_GDC2_SCROLL: TIMEOUT");
  end

endmodule
