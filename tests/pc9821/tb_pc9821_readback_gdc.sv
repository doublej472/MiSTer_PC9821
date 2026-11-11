`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The GDC block's parameter read-back and mode read-back against NP2kai (and the palette row): 0x62 pops the text GDC's parameter queue (CSRR 0xE0 answers {CSRW0, CSRW1, CSRW2&3, 0, 0} and LPEN 0xC0 the three never-written LPEN slot bytes 00 00 00, one byte per read, 0xFF when empty), 0xA2 does the same for the graphics GDC, whose CSRR answer is the Xe10's {EAD[7:0], EAD[15:8], 0xF0|EAD[17:16], MASK[7:0], MASK[15:8]} (docs/probes/gdc-conformance/xe10-2.5MHz/GDCCURS.CSV raw_curd; GDCWG's WG row reads F8 in byte 2) instead of returning a second status byte (the machine's own `GDC status 60 A0 A2: 05 04 ff` pins the empty answer at 0xFF) and 0xA0 status bit 0 flags that queue nonempty (read-back data available), 0x6A reads 00 whatever MODE FF2 holds (the Xe10, docs/probes/KIT1-XE10-PEGCRD.TXT `MODE 6A=00` in the 16- and 256-colour states, where NP2kai gdc_i6a returns its mode2), and the 16-colour analogue palette data ports answer the LOW NIBBLE of the byte the guest wrote with the upper four bits 0 (the probed Xe10, docs/probes/PEGCRD-XE10.TXT: wrote R=FF G=00 B=7F read 0F 00 0F; wrote 12 34 56 read 02 04 06; entries 5A and A5 index the 16-entry table as 0A and 05), the 0xA8 index register round-trips the FULL byte (`out 0xA8,0xAB / in 0xA8` reads 0xAB, not 0x0B: NP2kai io/gdc.c:841 stores `gdc.palnum = dat` unmasked and :913-919 returns it verbatim), the 16-colour palette read mirror is 16 entries indexed palnum & 15 (the Xe10's 16-colour palette), and the PEGC 256-colour mirror is 256 entries at the UNMASKED 8-bit index with full-byte channels read back verbatim (NP2kai anareg[16*3 + palnum*4 + c], io/gdc.c:852-953; MAME returns 0 in 256-colour mode - the recorded divergence, capture-pending), with the 16-entry mirror unchanged after the mode round trip. FAIL-FIRST: on the pre-fix tree the index reads 0x0B, the 0x15 write aliases onto entry 5 (masked), and the 16-colour channels read the full byte instead of the capture's nibble. Plus the CG block's three register ports: 0xA1/0xA3/0xA5 READ BACK their latches (docs/probes/PORTS.TXT reads 00A1=2F 00A3=57 00A5=0F with the open ports 0xA7/0xAB/0xAD/0xAF beside them all FF, and six more read-only captures repeat those bytes), where NP2kai's cgromia1 (a read handler only at index 4) and the old open-0xFF arm are both wrong. The slave's 0xA0 status bit 2 (FIFO empty) is the queue's complement - 0x04 empty, 0x01 once a read-back is armed (Xe10 capture docs/probes/RDBACK.TXT:172-173) - and the six CRTC render registers 0x70..0x7A read back as found (00 0F 10 00 00 00, RDBACK.TXT:82-87) and store five bits each (NP2kai crtc_o70 `dat &= 0x1f`). The graphics display/access page latches 0xA4/0xA6 read back their own bit (as found 0, RDBACK.TXT:100-101).
//
// The GDC block's parameter read-back and mode read-back against NP2kai
// (P2/P3/P6 and the palette row): 0x62 pops the text GDC's parameter
// queue (CSRR 0xE0 answers {CSRW0, CSRW1, CSRW2&3, 0, 0} and LPEN 0xC0 the three
// never-written LPEN slot bytes 00 00 00, one byte per read, 0xFF when empty),
// 0xA2 does the same for the graphics GDC, whose CSRR answer is the Xe10's {EAD[7:0],
// EAD[15:8], 0xF0|EAD[17:16], MASK[7:0], MASK[15:8]} (GDCCURS.CSV raw_curd; the master's
// 0x62 shape has no capture and stays NP2kai's) instead of returning a second status
// byte (the machine's own `GDC status 60 A0 A2: 05 04 ff` pins the empty answer
// at 0xFF) and 0xA0 status bit 0 flags that queue nonempty (read-back data
// available), 0x6A reads 00 whatever MODE FF2 holds (the Xe10's
// KIT1-XE10-PEGCRD.TXT, against NP2kai's mode2 echo), and the
// 16-colour palette data ports answer the FULL byte the guest wrote (write 0xFF,
// read 0xFF - the old nibble shape answered 0x0F), the 0xA8 index register
// round-trips the FULL byte (`out 0xA8,0xAB / in 0xA8` reads 0xAB, not 0x0B:
// NP2kai io/gdc.c:841 stores `gdc.palnum = dat` unmasked and :913-919 returns it
// verbatim), and the palette read mirror is 16 entries indexed palnum & 15 (the
// Xe10's own 16-colour palette; NP2kai's 256-entry anareg mirror is the PEGC's,
// out of scope - reverted for area). Two more rows come from ONE machine capture
// in digital mode and contradict BOTH software models, so the capture is their
// sole source: the 0x7C BYTE read is open bus 0xFF (the probe wrote 0x5A and
// read 0xFF) and the four DIGITAL palette ports read back MASKED with 0x77
// (`00A8 wrote=AB after=23`, `00AA/00AC/00AE wrote=FF after=77`) - the 16-colour
// ANALOGUE path is untouched by that mask. Plus the CG block's three
// register ports: 0xA1/0xA3/0xA5 READ BACK their latches (docs/probes/PORTS.TXT
// reads 00A1=2F 00A3=57 00A5=0F with the open ports 0xA7/0xAB/0xAD/0xAF beside
// them all FF, and six more read-only captures repeat those bytes), where
// NP2kai's cgromia1 (a read handler only at index 4) and the old open-0xFF arm
// are both wrong.
//
// ---- the bench's own account of where each expectation comes from ----
//
//  1. THE PARAMETER QUEUE MECHANICS. NP2kai gdc_i62/gdc_ia2 (io/gdc.c:684-692,
//     813-820): `if (snd) { snd--; return para[ptr++]; } return 0xff;` - a read
//     RETURNS one byte and CONSUMES it, and an empty queue answers 0xFF. gdc_work
//     reloads the queue from gdc_cmd.tbl's two `indatas` rows and any new
//     command REPLACES it (io/gdc.c:327). The five CSRR bytes are
//     {para[CSRW+0], para[CSRW+1], para[CSRW+2] & 3, 0, 0} (io/gdc.c:328-337);
//     LPEN's three are para[GDC_LPEN..2] = para[29..31] (io/gdc_cmd.h:34,38:
//     GDC_CSRFORM = 9, GDC_LPEN = 29 - the old "both slot 29" claim was FALSE),
//     slots NO command writes (no gdc_cmd.tbl row stores to pos 29) which
//     gdc_reset zero-fills (io/gdc.c:1160): the answer is 00 00 00, whatever
//     the CSRFORM block holds.
//     [source: NP2kai io/gdc.c + io/gdc_cmd.tbl, the primary reference]
//
//  2. THE EMPTY ANSWER AT 0xA2 IS THE MACHINE'S. probes/PROBE.TXT's probe line
//     `GDC status 60 A0 A2: 05 04 ff` reads all three ports back to back: 0xA0
//     carried the status (0x04) while 0xA2 read 0xFF. The old arm answered 0xA2
//     with the same status byte as 0xA0 - refuted by that capture.
//     [source: docs/probes/PROBE.TXT, a real PC-9821Xe10]
//
//  3. 0xA0 STATUS BIT 0 IS READ-BACK DATA AVAILABLE - the queue nonempty.
//     NP2kai's gdc_ia0 does `if (gdc.s.snd) ret |= 0x01;` (io/gdc.c:764-765):
//     the slave raises bit 0 while its parameter read-back queue holds bytes and
//     drops it when drained. The 2M-sample histogram's dead bit 0 at 0xA0
//     (the machine's probe results "GDC status") does not refute that: the
//     probe never arms a slave read-back (tools/hwprobe/probe2/probe2.s:1684-1730, `sec_gdc:`
//     samples the bare status port), so the queue is empty all capture and
//     "hardwired 0" is indistinguishable from "empty" - NP2kai is the authority.
//     [source: NP2kai io/gdc.c, the primary reference]
//
//  4. THE 0x6A READ. NP2kai gdc_i6a returns the live gdc.mode2 (io/gdc.c:700-704),
//     but the machine reads 0x6A as 00 in the 16-colour and the 256-colour state:
//     docs/probes/KIT1-XE10-PEGCRD.TXT:3 `MODE 6A=00 9A0_04=01` and
//     KIT1-XE10-PEGCRD.TXT:14 `MODE 6A=00 9A0_04=00 9A0_07=00 9A0_08=01 9A0_0A=01`
//     (docs/probes/PEGCRD-XE10.TXT:3 reads the same). The capture outranks NP2kai.
//
//  5. THE PALETTE SHAPE (CORRECTED by docs/probes/PEGCRD-XE10.TXT: the measured Xe10 reads the
//     16-colour analogue palette back as the LOW NIBBLE only, `WROTE_R=FF G=00 B=7F READ_R=0F
//     G=00 B=0F`; the paragraph below records the NP2kai model the capture outranks). NP2kai stores the whole written byte per channel in
//     gdc.anareg and reads it back verbatim (gdc_oaa/oac/oae + gdc_iaa/iac/iae,
//     io/gdc.c:852-953). The RTL stored io_din[3:0] and answered 0x0F for a
//     written 0xFF - the visual is 4-bit (a 16-colour DAC) but the READBACK is
//     the full byte. This is the
//     ANALOGUE (16-colour) path only: the machine's DIGITAL read-back is masked
//     with 0x77 and is a separate finding below (finding 4d), NOT a change here.
//
//  4b. THE 0xA8 INDEX REGISTER is the FULL byte, round-trip. NP2kai's gdc_oa8
//     stores `dat` unmasked in gdc.palnum (io/gdc.c:841) and gdc_ia8 returns
//     gdc.palnum verbatim (:913-919), so `out 0xA8,0xAB / in 0xA8` reads 0xAB.
//     The register is architecturally 8 bits - the PEGC 256-colour palette
//     indexes through it (io/gdc.c:854). The old 4-bit register answered 0x0B.
//
//  4c. THE READ MIRROR IS 16 ENTRIES, indexed palnum & 15 (the Xe10's 16-colour
//     palette; the DAC and displayed table take the same masked index, gdc.c:862).
//     NP2kai's 256-entry anareg[palnum*3+c] mirror is the PEGC's 256-colour
//     palette, out of scope here - reverted for area (the 256-entry register
//     array cost ~6 Kbit of logic on a ~99%-full device).
//
//  4d. THE 0x7C BYTE READ IS OPEN BUS, AND THE DIGITAL PALETTE IS MASKED.
//     Both come from ONE machine run in digital mode (probes/RDBACK.TXT:147-152)
//     and both contradict both software models, so the capture is the sole
//     source: `port=007C ... wrote=5A after=FF` (a byte read that answers a live
//     grcg.modereg would have read 0x5A) and `00A8 wrote=AB after=23`,
//     `00AA/00AC/00AE wrote=FF after=77` (the 0x77 mask). The rows are in the
//     MACHINE section below; docs/probes/RDBACK.TXT holds the bytes.
//
//  FAIL-FIRST: on the pre-fix tree the 0xA8 index reads 0x0B for
//  0xAB; the mirror is 16-entry masked (palnum 0x15 and 0x05 are one entry).
//
//  5. 0xA1/0xA3/0xA5 READ BACK their latches. This was P7's opposite ("write-only,
//     open 0xFF") on NP2kai's authority alone - that reference attaches a read handler
//     only at cgrom index 4 (0xA9, io/cgrom.c:240-243) - but the machine drives a byte at
//     all three: PORTS.TXT's tab_latches reads 00A1=2F 00A3=57 00A5=0F (the open ports
//     0xA7/0xAB/0xAD/0xAF beside them read FF), repeated across VRAM.TXT, MEMSW.TXT,
//     PIT-fixed.TXT, PITPH.TXT, RDBACK.TXT and WIPE-rerun.TXT, and the bytes are the
//     latches the firmware had selected. The hardware outranks NP2kai, so the three ports
//     return cg_code[15:8] / cg_code[7:0] / {2'b00, ~cg_lr, cg_line}, which also makes a
//     guest's own write round-trip. [source: docs/probes/PORTS.TXT]
//
// FAIL-FIRST (rtlrev-video): the sync_abort_* checks fail on the tree whose SYNC
// capture survived a following command (the CSRW bytes became SYNC bytes, CSRR
// answered the stale cursor, the slave's AL/VBP moved).
//
// FAIL-FIRST (this revision): the six lpen_* checks pin the 0xC0 answer to the
// NP2kai slot value 00 and the a0_status_bit0_* checks to the queue-nonempty
// flag; the pre-fix RTL answers the CSRFORM bytes instead (0F C0 7B master,
// 01 11 22 slave) and holds 0xA0 bit 0 at 0 with five bytes queued. The earlier
// cases this bench's first pass fixed (queue mechanics, the palette
// shape) pin their post-fix values; the P6 0x6A rows fail on the tree that echoed
// mode2 (01 / 03 there) and pass on the one that reads 00 and still pass; the three CG read-back cases
// fail on the tree that answered 0xFF (the P7 revision) and pass here.

module tb_pc9821_readback_gdc;
  reg clk_sys = 0;
  always #5 clk_sys = ~clk_sys;
  reg rst_n_sys = 0;
  reg pixel_ce = 1;

  reg        io_wr = 0;
  reg        io_rd = 0;
  reg  [7:0] io_addr = 0;
  reg  [7:0] io_din = 0;
  wire [7:0] io_dout;


  reg [13:0] tram_cpu_addr = 0;
  reg [7:0] tram_cpu_din = 0;
  reg tram_cpu_we = 0;
  wire [7:0] tram_cpu_dout;

  reg [17:0] font_ld_addr = 0;
  reg [15:0] font_ld_data = 0;
  reg font_ld_we = 0;

  reg [4:0] cg_win_byte_sel = 0;
  reg cg_win_rd = 0;
  wire [7:0] cg_win_dout;
  reg [7:0] cg_win_din = 0;
  reg cg_win_we = 0;
  wire cg_win_byte_hold;

  wire [18:0] font_req_addr;
  wire font_req;
  reg font_word_valid = 0;
  reg [31:0] font_word_data = 0;
  wire cg_rd_hold;

  reg cg_record_restore = 0;
  reg [3:0] bios_set = 4'd0;   // the record's model field: 0 = Xe10 (entry 0)
  wire vsync_active, vsync_irq, vsync_edge;
  reg vsync_irq_arm = 0;
  wire disp_on, gfx_access_page, gfx_disp, gfx_egc_gate;
  wire [15:0] gfx_line_addr;
  wire gfx_walk_page;   // the packed walk's page bit; not this bench's subject (parked for (.*))
  wire [6:0] cfg_ram_mib = 7'd0;
  wire cfg_seed_en = 1'b0;
  wire cfg_seed_reload = 1'b0;

  wire [15:0] dbg_sad;
  wire [7:0] dbg_pitch;
  wire dbg_col40, dbg_disp;
  wire [15:0] dbg_wk_skips;
  wire text_opaque, text_cell;
  wire [11:0] text_colour;
  wire [9:0] pix_dot;
  wire pix_h_active, pix_v_active;
  wire gfx_mode16;
  wire [31:0] gfx_dig;
  wire pal_wr_en;
  wire [3:0] pal_wr_idx;
  wire [1:0] pal_wr_chan;
  wire [3:0] pal_wr_data;
  wire hs_out, vs_out, de_out;

  // Parked: the 200-line interleave's odd-line output (pc9821_crtc's seam; this bench
  // does not check it - tb_pc9821_interleave_200 does).
  wire gfx_odd_line;
  // ==== DUT ====
  // The ONE OSD hardware-switch field, as a LIST POSITION at ENTRY 0 - the measured
  // machine's own boot/FDD nibble (0x00). pc9821_crtc decodes and latches it and seeds its
  // TRAM tail at machine reset; it is declared so the wildcard `.*` instance below connects
  // it rather than leaving the port at zero. The base memory is hardcoded to 640 KB inside
  // pc9821_crtc.
  reg [2:0] cfg_fdd_mode = 3'd0;

  pc9821_gdc_text_dut dut (.*);

  integer errors = 0, cases = 0;
  reg [7:0] value;

  // ==== CHECKS ====
  task automatic check(input [8*48-1:0] name, input [15:0] got, input [15:0] want);
    begin
      cases = cases + 1;
      if (got !== want) begin
        $display("MISMATCH %0s: rtl=0x%04x np2kai=0x%04x", name, got, want);
        errors = errors + 1;
      end
      else $display("ok       %0s = 0x%04x", name, got);
    end
  endtask

  // One GDCCURS/GDCWG capture row on the graphics GDC: CSRW (e0 e1 e2), MASK (m0 m1) when
  // `set_mask`, then CSRR and the five bytes the machine answered.
  task automatic curd_row(input [8*48-1:0] name, input [7:0] e0, input [7:0] e1, input [7:0] e2,
                          input set_mask, input [7:0] m0, input [7:0] m1,
                          input [7:0] x0, input [7:0] x1, input [7:0] x2, input [7:0] x3, input [7:0] x4);
    reg [7:0] v;
    reg [39:0] got;
    begin
      write_io(8'hA2, 8'h49); write_io(8'hA0, e0); write_io(8'hA0, e1); write_io(8'hA0, e2);
      if (set_mask) begin write_io(8'hA2, 8'h4A); write_io(8'hA0, m0); write_io(8'hA0, m1); end
      write_io(8'hA2, 8'hE0);
      read_io(8'hA2, v); got[39:32] = v; read_io(8'hA2, v); got[31:24] = v;
      read_io(8'hA2, v); got[23:16] = v; read_io(8'hA2, v); got[15:8] = v;
      read_io(8'hA2, v); got[7:0] = v;
      check(name, {8'h00, got[39:32]}, {8'h00, x0});
      check(name, {8'h00, got[31:24]}, {8'h00, x1});
      check(name, {8'h00, got[23:16]}, {8'h00, x2});
      check(name, {8'h00, got[15:8]},  {8'h00, x3});
      check(name, {8'h00, got[7:0]},   {8'h00, x4});
    end
  endtask

  task automatic write_io(input [7:0] portnum, input [7:0] data);
    begin
      @(negedge clk_sys); io_addr = portnum; io_din = data; io_wr = 1;
      @(negedge clk_sys); io_wr = 0;
    end
  endtask

  // A CPU read of the GDC block as the fabric runs it: the one-cycle read strobe,
  // then the data captured a cycle later (device_rd_wait in pc9821_system). The
  // queue's pop happens at the strobe and the returned byte survives it in the
  // read-data register.
  task automatic read_io(input [7:0] portnum, output [7:0] data);
    begin
      @(negedge clk_sys); io_addr = portnum; io_rd = 1;
      @(negedge clk_sys); io_rd = 0;
      @(negedge clk_sys); #1 data = io_dout;
    end
  endtask

  initial begin
    repeat (8) @(negedge clk_sys);
    rst_n_sys = 1;
    repeat (4) @(negedge clk_sys);

    // ==== the six CRTC render registers 0x70..0x7A read back ================
    // As found on the Xe10 (docs/probes/RDBACK.TXT:82-87 `0070=00 0072=0F 0074=10 0076=00
    // 0078=00 007A=00`), each read is its own register; then a write stores five bits
    // (NP2kai crtc_o70 `dat &= 0x1f`, io/crtc.c:10-17), so six distinct bytes read back
    // at their own ports and 0xFF reads 0x1F.
    read_io(8'h70, value); check("crtc_70_as_found", {8'h00, value}, 16'h0000);
    read_io(8'h72, value); check("crtc_72_as_found", {8'h00, value}, 16'h000F);
    read_io(8'h74, value); check("crtc_74_as_found", {8'h00, value}, 16'h0010);
    read_io(8'h76, value); check("crtc_76_as_found", {8'h00, value}, 16'h0000);
    read_io(8'h78, value); check("crtc_78_as_found", {8'h00, value}, 16'h0000);
    read_io(8'h7A, value); check("crtc_7a_as_found", {8'h00, value}, 16'h0000);
    write_io(8'h70, 8'h01); write_io(8'h72, 8'h02); write_io(8'h74, 8'h03);
    write_io(8'h76, 8'h04); write_io(8'h78, 8'h05); write_io(8'h7A, 8'hE6);
    read_io(8'h70, value); check("crtc_70_roundtrip", {8'h00, value}, 16'h0001);
    read_io(8'h72, value); check("crtc_72_roundtrip", {8'h00, value}, 16'h0002);
    read_io(8'h74, value); check("crtc_74_roundtrip", {8'h00, value}, 16'h0003);
    read_io(8'h76, value); check("crtc_76_roundtrip", {8'h00, value}, 16'h0004);
    read_io(8'h78, value); check("crtc_78_roundtrip", {8'h00, value}, 16'h0005);
    read_io(8'h7A, value); check("crtc_7a_roundtrip_masked_5_bits", {8'h00, value}, 16'h0006);
    write_io(8'h70, 8'hFF);
    read_io(8'h70, value); check("crtc_70_ff_reads_1f", {8'h00, value}, 16'h001F);
    write_io(8'h70, 8'h00); write_io(8'h72, 8'h0F); write_io(8'h74, 8'h10);   // as found again
    write_io(8'h76, 8'h00); write_io(8'h78, 8'h00); write_io(8'h7A, 8'h00);

    // 0x64 reads 0x1F after the guest writes 0x1F (docs/probes/RDBACK.TXT:78 `0064=1F`; the
    // probe had written it first, so a latch and a constant both fit), not open bus.
    write_io(8'h64, 8'h1F);
    read_io(8'h64, value); check("port_64_as_found_1f", {8'h00, value}, 16'h001F);

    // ==== the graphics page latches 0xA4 (display) and 0xA6 (access) read back ====
    // As found 0 (docs/probes/RDBACK.TXT:100-101 `00A4=00 ... 00A6=00`); NP2kai io/gdc.c
    // gdc_ia4/gdc_ia6 return the display and access page latches, each at its own port.
    read_io(8'hA4, value); check("page_a4_as_found", {8'h00, value}, 16'h0000);
    read_io(8'hA6, value); check("page_a6_as_found", {8'h00, value}, 16'h0000);
    write_io(8'hA4, 8'h01);
    read_io(8'hA4, value); check("page_a4_display_set", {8'h00, value}, 16'h0001);
    read_io(8'hA6, value); check("page_a6_unmoved_by_a4", {8'h00, value}, 16'h0000);
    write_io(8'hA4, 8'h00); write_io(8'hA6, 8'h01);
    read_io(8'hA4, value); check("page_a4_unmoved_by_a6", {8'h00, value}, 16'h0000);
    read_io(8'hA6, value); check("page_a6_access_set", {8'h00, value}, 16'h0001);
    write_io(8'hA6, 8'h00);

    // ==== P2: the text GDC's parameter read-back (0x62) ====================
    // CSRW 0x49 takes three parameter bytes; CSRR 0xE0 queues five answer bytes.
    write_io(8'h62, 8'h49);       // CSRW
    write_io(8'h60, 8'h12);       // ead low
    write_io(8'h60, 8'h34);       // ead high
    write_io(8'h60, 8'h07);       // ead bits 16+ (answered masked to 2 bits)
    write_io(8'h62, 8'hE0);       // CSRR: queue {12, 34, 07&3, 0, 0}
    read_io(8'h62, value); check("csrr_byte0_ead_low",  {8'h00, value}, 16'h0012);
    read_io(8'h62, value); check("csrr_byte1_ead_high", {8'h00, value}, 16'h0034);
    read_io(8'h62, value); check("csrr_byte2_ead_hi2_masked", {8'h00, value}, 16'h0003);
    read_io(8'h62, value); check("csrr_byte3_zero", {8'h00, value}, 16'h0000);
    read_io(8'h62, value); check("csrr_byte4_zero", {8'h00, value}, 16'h0000);
    read_io(8'h62, value); check("queue_drained_is_ff", {8'h00, value}, 16'h00ff);

    // A non-consuming look (hierarchical - a CPU read ALWAYS strobes and
    // consumes): the queue head is still CSRR byte 0, and the two reads after it
    // serve both bytes in order.
    write_io(8'h62, 8'hE0);
    if (dut.u_crtc.gdc_snd_head !== 8'h12) begin
      $display("MISMATCH queue head: rtl=%02x np2kai=12", dut.u_crtc.gdc_snd_head);
      errors = errors + 1;
    end
    read_io(8'h62, value); check("read_serves_the_head", {8'h00, value}, 16'h0012);
    read_io(8'h62, value); check("read_pops_the_next", {8'h00, value}, 16'h0034);

    // LPEN 0xC0 queues para[29..31] - the never-written light-pen slots, 00
    // 00 00 since gdc_reset (io/gdc.c:1160) - NOT the CSRFORM block
    // (io/gdc_cmd.h:34,38: GDC_CSRFORM = 9, GDC_LPEN = 29). Writing a
    // distinctive CSRFORM first proves the answer does not track it.
    write_io(8'h62, 8'h4B);       // CSRFORM
    write_io(8'h60, 8'h0F);
    write_io(8'h60, 8'hC0);
    write_io(8'h60, 8'h7B);
    write_io(8'h62, 8'hC0);       // LPEN
    read_io(8'h62, value); check("lpen_byte0_slot29_zero", {8'h00, value}, 16'h0000);
    read_io(8'h62, value); check("lpen_byte1_slot30_zero", {8'h00, value}, 16'h0000);
    read_io(8'h62, value); check("lpen_byte2_slot31_zero", {8'h00, value}, 16'h0000);
    read_io(8'h62, value); check("lpen_drained_is_ff", {8'h00, value}, 16'h00ff);

    // Any new command REPLACES the queue (NP2kai gdc_work's snd = indatas).
    write_io(8'h62, 8'hE0);
    write_io(8'h62, 8'h00);       // RESET: indatas 0, discards the queue
    read_io(8'h62, value); check("new_command_replaces_the_queue", {8'h00, value}, 16'h00ff);

    // ==== P3: the graphics GDC's parameter read-back (0xA2) ===============
    // Empty 0xA2 is 0xFF, NOT the status byte (machine: `05 04 ff`).
    read_io(8'hA2, value); check("a2_empty_is_ff_not_status", {8'h00, value}, 16'h00ff);
    // The slave's own CSRW/CSRR round trip.
    write_io(8'hA2, 8'h49);       // slave CSRW
    write_io(8'hA0, 8'hAB);
    write_io(8'hA0, 8'hCD);
    write_io(8'hA0, 8'h07);
    write_io(8'hA2, 8'hE0);       // slave CSRR
    read_io(8'hA2, value); check("slave_csrr_byte0", {8'h00, value}, 16'h00ab);
    read_io(8'hA2, value); check("slave_csrr_byte1", {8'h00, value}, 16'h00cd);
    // The Xe10's five CURD bytes (docs/probes/gdc-conformance/xe10-2.5MHz/GDCCURS.CSV
    // raw_curd; NP2kai's {CSRW0, CSRW1, CSRW2 & 3, 0, 0} is refuted): CSRW dAD 0 -> mask 0001.
    read_io(8'hA2, value); check("slave_csrr_byte2_f0_or_ead17_16", {8'h00, value}, 16'h00f3);
    read_io(8'hA2, value); check("slave_csrr_byte3_mask_lo", {8'h00, value}, 16'h0001);
    read_io(8'hA2, value); check("slave_csrr_byte4_mask_hi", {8'h00, value}, 16'h0000);
    read_io(8'hA2, value); check("slave_queue_drained_is_ff", {8'h00, value}, 16'h00ff);
    // GDCCURS.CSV raw_curd rows (CSRW EAD/dAD, then CSRR) and GDCWG.CSV's WG row (`28-88-F8-FF-FF`).
    curd_row("capture_FF-FF-F1-00-80", 8'hFF, 8'hFF, 8'hF1, 0, 8'h00, 8'h00, 8'hFF, 8'hFF, 8'hF1, 8'h00, 8'h80);
    curd_row("capture_FF-FF-F3-01-00", 8'hFF, 8'hFF, 8'h03, 0, 8'h00, 8'h00, 8'hFF, 8'hFF, 8'hF3, 8'h01, 8'h00);
    curd_row("capture_00-00-F0-00-04", 8'h00, 8'h00, 8'hA0, 0, 8'h00, 8'h00, 8'h00, 8'h00, 8'hF0, 8'h00, 8'h04);
    curd_row("capture_28-88-F8-FF-FF", 8'h28, 8'h88, 8'h08, 1, 8'hFF, 8'hFF, 8'h28, 8'h88, 8'hF8, 8'hFF, 8'hFF);
    // The slave's LPEN answers its OWN para[29..31] - 00 00 00 whatever the
    // CSRFORM capture holds (and that capture's byte 0 is still the line step).
    write_io(8'hA2, 8'h4B);
    write_io(8'hA0, 8'h01);
    write_io(8'hA0, 8'h11);
    write_io(8'hA0, 8'h22);
    write_io(8'hA2, 8'hC0);
    read_io(8'hA2, value); check("slave_lpen_byte0_slot29", {8'h00, value}, 16'h0000);
    read_io(8'hA2, value); check("slave_lpen_byte1_slot30", {8'h00, value}, 16'h0000);
    read_io(8'hA2, value); check("slave_lpen_byte2_slot31", {8'h00, value}, 16'h0000);
    read_io(8'hA2, value); check("slave_lpen_drained_is_ff", {8'h00, value}, 16'h00ff);
    if (dut.u_gdc2.gdc2_lr !== 5'd1) begin
      $display("MISMATCH slave csrform byte 0 is still the line step: rtl=%02x want 01", dut.u_gdc2.gdc2_lr);
      errors = errors + 1;
    end

    // ==== 0xA0 status bit 0: read-back data available =====================
    // NP2kai gdc_ia0: `if (gdc.s.snd) ret |= 0x01;` (io/gdc.c:764-765) - bit 0
    // is set while the 0xA2 queue holds bytes and clears when it drains. A
    // status read of 0xA0 does NOT pop (only 0xA2 does), so the flag is pollable.
    read_io(8'hA0, value); check("a0_status_bit0_empty_queue", {15'h0, value[0]}, 16'h0000);
    // BIT 2 (FIFO empty) follows the same queue. The Xe10 captured the slave status as 0x04 before
    // arming a read-back and 0x01 after (docs/probes/RDBACK.TXT:172 `00A0 status before arm = 04 ;
    // after 0xE0 arm = 01`, and :173 `after 0xC0 arm = 01`): bit 2 CLEARS while data is queued.
    check("a0_status_bit2_empty_queue_set", {15'h0, value[2]}, 16'h0001);
    write_io(8'hA2, 8'hE0);       // slave CSRR: five bytes queued
    read_io(8'hA0, value); check("a0_status_bit0_five_queued", {15'h0, value[0]}, 16'h0001);
    check("a0_status_bit2_queued_clear", {15'h0, value[2]}, 16'h0000);
    read_io(8'hA2, value);        // pop 1 of 5
    read_io(8'hA0, value); check("a0_status_bit0_four_left", {15'h0, value[0]}, 16'h0001);
    read_io(8'hA2, value);        // pop 2 of 5
    read_io(8'hA2, value);        // pop 3 of 5
    read_io(8'hA2, value);        // pop 4 of 5
    read_io(8'hA0, value); check("a0_status_bit0_one_left", {15'h0, value[0]}, 16'h0001);
    read_io(8'hA2, value);        // pop 5 of 5
    read_io(8'hA0, value); check("a0_status_bit0_drained", {15'h0, value[0]}, 16'h0000);
    check("a0_status_bit2_drained_set", {15'h0, value[2]}, 16'h0001);

    // ==== P6: 0x6A reads 00 whatever MODE FF2 holds (KIT1-XE10-PEGCRD.TXT) ====
    write_io(8'h6A, 8'h02);       // FF2 num 1 OFF
    read_io(8'h6A, value); check("mode2_6a_reads_00", {8'h00, value}, 16'h0000);
    write_io(8'h6A, 8'h03);       // FF2 num 1 ON (dat 2/3 form)
    read_io(8'h6A, value); check("mode2_6a_00_after_num1_on", {8'h00, value}, 16'h0000);
    write_io(8'h6A, 8'h01);       // num 0 ON: 16 colours (the capture's `9A0_04=01` row)
    read_io(8'h6A, value); check("mode2_6a_00_in_16_colours", {8'h00, value}, 16'h0000);
    write_io(8'h6A, 8'h07);       // EGC/PEGC write enable ON (num 3)
    write_io(8'h6A, 8'h21);       // num 0x10 ON: 256 colours (the capture's `9A0_0A=01` row)
    read_io(8'h6A, value); check("mode2_6a_00_in_256_colours", {8'h00, value}, 16'h0000);
    write_io(8'h6A, 8'h20);       // 256 colours OFF
    write_io(8'h6A, 8'h06);       // write enable OFF
    write_io(8'h6A, 8'h02);       // num 1 OFF again
    read_io(8'h6A, value); check("mode2_6a_00_after_num1_off", {8'h00, value}, 16'h0000);
    // ==== the 16-colour analogue palette reads back the LOW NIBBLE ==========
    // docs/probes/PEGCRD-XE10.TXT (the measured Xe10, 16-colour analogue mode, 0x9A0 index 0x04
    // read 1): `16  ENTRY=02 WROTE_R=FF G=00 B=7F READ_R=0F G=00 B=0F` - the upper four bits of
    // 0xAA/0xAC/0xAE read 0. NP2kai io/gdc.c gdc_iaa/iac/iae answers the whole byte; the capture
    // outranks it (recorded divergence). ENTRY=5A and A5 index the 16-entry table as 0x0A / 0x05.
    begin : pal16_capture
      reg [7:0] e [0:5];  reg [7:0] wr [0:5]; reg [7:0] wg [0:5]; reg [7:0] wb [0:5];
      reg [7:0] rr [0:5]; reg [7:0] rg [0:5]; reg [7:0] rb [0:5];
      integer k;
      e[0]=8'h00; wr[0]=8'h00; wg[0]=8'h00; wb[0]=8'h00; rr[0]=8'h00; rg[0]=8'h00; rb[0]=8'h00;
      e[1]=8'h01; wr[1]=8'h12; wg[1]=8'h34; wb[1]=8'h56; rr[1]=8'h02; rg[1]=8'h04; rb[1]=8'h06;
      e[2]=8'h02; wr[2]=8'hFF; wg[2]=8'h00; wb[2]=8'h7F; rr[2]=8'h0F; rg[2]=8'h00; rb[2]=8'h0F;
      e[3]=8'h0B; wr[3]=8'h5A; wg[3]=8'hA5; wb[3]=8'h3C; rr[3]=8'h0A; rg[3]=8'h05; rb[3]=8'h0C;
      e[4]=8'h5A; wr[4]=8'h11; wg[4]=8'h22; wb[4]=8'h33; rr[4]=8'h01; rg[4]=8'h02; rb[4]=8'h03;
      e[5]=8'hA5; wr[5]=8'h44; wg[5]=8'h55; wb[5]=8'h66; rr[5]=8'h04; rg[5]=8'h05; rb[5]=8'h06;
      for (k = 0; k < 6; k = k + 1) begin
        write_io(8'hA8, e[k]);
        write_io(8'hAA, wg[k]); write_io(8'hAC, wr[k]); write_io(8'hAE, wb[k]);
        read_io(8'hAA, value); check("pal16_cap_g", {8'h00, value}, {8'h00, rg[k]});
        read_io(8'hAC, value); check("pal16_cap_r", {8'h00, value}, {8'h00, rr[k]});
        read_io(8'hAE, value); check("pal16_cap_b", {8'h00, value}, {8'h00, rb[k]});
      end
      // The 5A and A5 rows wrote entries 0x0A and 0x05; a read at the aliased 8-bit index sees them.
      write_io(8'hA8, 8'h0A);
      read_io(8'hAC, value); check("pal16_cap_5A_is_0A", {8'h00, value}, 16'h0001);
      write_io(8'hA8, 8'h05);
      read_io(8'hAA, value); check("pal16_cap_A5_is_05", {8'h00, value}, 16'h0005);
    end
    // ==== the 0xA8 index register round-trips the FULL byte ===
    // NP2kai io/gdc.c:841 `gdc.palnum = dat` and :913-919 return gdc.palnum
    // verbatim, so 0xAB in is 0xAB out; the old 4-bit register answered 0x0B.
    write_io(8'hA8, 8'hAB);
    read_io(8'hA8, value); check("palette_index_full_byte", {8'h00, value}, 16'h00ab);
    // ==== the read mirror is 16 entries, indexed palnum & 15 (PEGC out of scope) ====
    // The mirror, the DAC and the displayed table all take the masked index
    // (palnum & 15, gdc.c:862), so palnum 0x15 and 0x05 address the SAME entry.
    write_io(8'hA8, 8'h15);
    write_io(8'hAA, 8'h77);       // entry 5 green (0x15 & 15 = 5)
    write_io(8'hA8, 8'h05);
    write_io(8'hAA, 8'h33);       // entry 5 green again (overwrites)
    read_io(8'hAA, value); check("entry5_own_byte", {8'h00, value}, 16'h0003);
    write_io(8'hA8, 8'h15);
    read_io(8'hAA, value); check("palnum15_masks_to_entry5", {8'h00, value}, 16'h0003);
    // The DAC index stays palnum & 15 (io/gdc.c:862 gdc_setanalogpal).
    if (dut.u_crtc.pal_wr_idx !== 4'd5) begin
      $display("MISMATCH display index: rtl=0x%02x np2kai=0x05 (gdc.c:862 palnum & 15)",
               dut.u_crtc.pal_wr_idx);
      errors = errors + 1;
    end

    // A never-written entry reads the 16-colour power-on table (pal_power_on),
    // not a PEGC ramp (out of scope): 0x12 & 15 = entry 2, whose green is 0x00.
    write_io(8'hA8, 8'h12);
    read_io(8'hAA, value); check("alias_reset_poweron", {8'h00, value}, 16'h0000);

    // The 8-colour digital readback is unchanged and stays. 0xA8 in digital
    // mode is degpal[3] both ways (io/gdc.c:844 gdc_setdegpalpack(3, dat),
    // :919 return gdc.degpal[3]).
    write_io(8'h6A, 8'h00);       // 16-colour OFF: digital palette
    write_io(8'hA8, 8'h37);
    read_io(8'hA8, value); check("digital_palette_a8_full_byte", {8'h00, value}, 16'h0037);
    read_io(8'hAA, value); check("digital_palette_g", {8'h00, value}, 16'h0015);

    // ==== the MACHINE's digital palette read-back: MASKED with 0x77 =========
    // probes/RDBACK.TXT:147 states the run's mode ("mode bytes (0068 FF1, 006A
    // FF2) = 18 00": FF1 0x18, FF2 0x00, i.e. DIGITAL), and the round-trip
    // block at :148-151 reads:
    //     00A8 before=37 wrote=AB after=23 back=37
    //     00AA before=15 wrote=FF after=77 back=15
    //     00AC before=26 wrote=FF after=77 back=26
    //     00AE before=04 wrote=FF after=77 back=04
    // 0xAB & 0x77 = 0x23 and 0xFF & 0x77 = 0x77, so the machine masks every one
    // of the four ports with 0x77 (bits 0-2 + 4-6; bit 3 is undefined, bit 7
    // unused) where that byte was written with the bit set. Both software models
    // return the raw byte (NP2kai gdc_ia8/iaa/iac/iae, io/gdc.c:913-954), so the
    // capture is the SOLE source for the mask. The 0x6A write above leaves this
    // bench in digital mode, which is the mode the capture ran in.
    // [source: docs/probes/RDBACK.TXT:147-151, a real PC-9821Xe10]
    write_io(8'hA8, 8'hAB);
    read_io(8'hA8, value); check("digital_a8_write_ab_reads_23", {8'h00, value}, 16'h0023);
    write_io(8'hAA, 8'hFF);
    read_io(8'hAA, value); check("digital_aa_write_ff_reads_77", {8'h00, value}, 16'h0077);
    write_io(8'hAC, 8'hFF);
    read_io(8'hAC, value); check("digital_ac_write_ff_reads_77", {8'h00, value}, 16'h0077);
    write_io(8'hAE, 8'hFF);
    read_io(8'hAE, value); check("digital_ae_write_ff_reads_77", {8'h00, value}, 16'h0077);
    // The mask is per-BYTE, not a clamp to something narrower: 0xF3 keeps bits
    // 0,1,4,5,6 and drops bit 3 and bit 7.
    write_io(8'hA8, 8'hF3);
    read_io(8'hA8, value); check("digital_a8_write_f3_reads_73", {8'h00, value}, 16'h0073);
    // The machine's own as-found bytes (RDBACK.TXT:148-151 before=, and the
    // snapshot's 00A8=37 00AA=15 00AC=26 00AE=04) are mask-invariant, so the
    // four rows above are the whole observable contract a read has.
    write_io(8'hA8, 8'h37); write_io(8'hAA, 8'h15);
    write_io(8'hAC, 8'h26); write_io(8'hAE, 8'h04);
    read_io(8'hA8, value); check("digital_a8_asfound_37", {8'h00, value}, 16'h0037);
    read_io(8'hAA, value); check("digital_aa_asfound_15", {8'h00, value}, 16'h0015);
    read_io(8'hAC, value); check("digital_ac_asfound_26", {8'h00, value}, 16'h0026);
    read_io(8'hAE, value); check("digital_ae_asfound_04", {8'h00, value}, 16'h0004);

    // ==== 0x7C's BYTE READ is OPEN BUS on the machine =======================
    // probes/RDBACK.TXT:152: `port=007C before=FF wrote=5A after=FF back=FF`.
    // The probe wrote a byte no live register could miss and the port still read
    // 0xFF, so the byte read is open bus; the hardware outranks NP2kai's live
    // grcg.modereg (io/crtc.c:46-50) and the old "the write-only model also
    // gives 0xFF when modereg holds 0xFF" reading of one as-found byte. Both
    // probe values are exercised here, with the register deliberately holding a
    // value that is NOT 0xFF so a live read cannot pass by accident.
    // The 16-bit `in ax,7Ch` form is not exercised here: the Xe10 reads it
    // FFFF (docs/probes/XE10T-XE10-AUDIT.TXT W007C), pinned by tb_pc9821_iobus.
    // [source: docs/probes/RDBACK.TXT:152, a real PC-9821Xe10]
    read_io(8'h7C, value); check("grcg_7c_byte_read_is_ff", {8'h00, value}, 16'h00ff);

    // ==== the CG code/line registers READ BACK their latches ================
    // The machine's own read-only scans drive a byte at 0xA1/0xA3/0xA5 - PORTS.TXT's
    // tab_latches reads `00A1=2F 00A3=57 00A5=0F` (with the genuinely open 0xA7/0xAB/0xAD/
    // 0xAF beside them all FF), repeated in VRAM.TXT / MEMSW.TXT / PIT-fixed.TXT /
    // PITPH.TXT / RDBACK.TXT / WIPE-rerun.TXT. The bytes are the latches the firmware
    // selected (code 0x2F57, line 0x0F), so a write-then-read must round-trip them; 0xFF
    // was NP2kai's cgromia1 answer (a read handler only at index 4) and NP2kai is the
    // weaker reference. [source: docs/probes/PORTS.TXT, a real PC-9821Xe10]
    write_io(8'hA1, 8'h2F);
    write_io(8'hA3, 8'h57);
    write_io(8'hA5, 8'h0F);
    read_io(8'hA1, value); check("cg_code_high_reads_latch", {8'h00, value}, 16'h002f);
    read_io(8'hA3, value); check("cg_code_low_reads_latch",  {8'h00, value}, 16'h0057);
    read_io(8'hA5, value); check("cg_line_reads_latch",      {8'h00, value}, 16'h000f);
    // ...and the three bytes still answer their OWN addresses, not 0xA1's latch.
    write_io(8'hA1, 8'h12); write_io(8'hA3, 8'h34); write_io(8'hA5, 8'h15);
    read_io(8'hA1, value); check("cg_code_high_second_value", {8'h00, value}, 16'h0012);
    read_io(8'hA3, value); check("cg_code_low_second_value",  {8'h00, value}, 16'h0034);
    read_io(8'hA5, value); check("cg_line_second_value",      {8'h00, value}, 16'h0015);

    // ==== THE PEGC 256-COLOUR READ MIRROR (pegc-scope-REPORT.md 4 row 5) ====
    // In 256-colour mode the mirror is 256 entries at the UNMASKED 8-bit index
    // with FULL-byte channels, read back verbatim (NP2kai anareg[16*3 +
    // palnum*4 + c], io/gdc.c:852-904 writes and :922-954 reads). MAME returns 0
    // for these ports in 256-colour mode (pc9821_a0_r's `256 color mode [xx] R`
    // arm) - the RECORDED DIVERGENCE, capture-pending; the hierarchy default is
    // NP2kai. The mode is entered exactly as the ITF's phase-2 block does it
    // (BANK4@0x1434-0x144C: 0x6A 07/21/06 around the select).
    write_io(8'h6A, 8'h07);
    write_io(8'h6A, 8'h21);
    write_io(8'h6A, 8'h06);
    write_io(8'hA8, 8'hAB);       // the UNMASKED index
    write_io(8'hAA, 8'hF1);       // G
    write_io(8'hAC, 8'hE2);       // R
    write_io(8'hAE, 8'hD3);       // B
    read_io(8'hAA, value); check("pegc_pal_g_full_byte", {8'h00, value}, 16'h00f1);
    read_io(8'hAC, value); check("pegc_pal_r_full_byte", {8'h00, value}, 16'h00e2);
    read_io(8'hAE, value); check("pegc_pal_b_full_byte", {8'h00, value}, 16'h00d3);
    read_io(8'hA8, value); check("pegc_pal_index_roundtrip", {8'h00, value}, 16'h00ab);
    // The index is the FULL byte in this mode: 0x15 and 0x05 are different entries.
    write_io(8'hA8, 8'h15);
    write_io(8'hAA, 8'h55);
    write_io(8'hA8, 8'h05);
    write_io(8'hAA, 8'h66);
    write_io(8'hA8, 8'h15);
    read_io(8'hAA, value); check("pegc_pal_unmasked_index_15", {8'h00, value}, 16'h0055);
    write_io(8'hA8, 8'h05);
    read_io(8'hAA, value); check("pegc_pal_unmasked_index_05", {8'h00, value}, 16'h0066);
    // A never-written entry reads 0x00 (NP2kai's zeroed anareg) - not the
    // 16-colour power-on table and not another entry's bytes.
    write_io(8'hA8, 8'h2B);
    read_io(8'hAA, value); check("pegc_pal_unwritten_is_zero", {8'h00, value}, 16'h0000);
    // Back in 16-COLOUR mode the 16-entry mirror is unchanged (entry 5 green is
    // still 0x33 from the masked-index section above). The 16-colour mode is
    // re-entered explicitly (FF2 num 0 ON): the digital section above left
    // mode2 bit 0 clear, and leaving the PEGC select restores exactly that state.
    write_io(8'h6A, 8'h07);
    write_io(8'h6A, 8'h20);       // the PEGC select off
    write_io(8'h6A, 8'h01);       // num 0 ON: 16-colour
    write_io(8'h6A, 8'h06);
    write_io(8'hA8, 8'h05);
    read_io(8'hAA, value); check("sixteen_colour_mirror_unchanged", {8'h00, value}, 16'h0003);

    // ==== A COMMAND ABORTS AN UNFINISHED SYNC BLOCK (both GDCs) ==============
    // NP2kai gdc_work's command branch reloads `item->ptr = gdc_cmd[data].pos;
    // item->rcv = gdc_cmd[data].outdatas;` for EVERY command byte (io/gdc.c), so a
    // SYNC (0x0E/0x0F) cut short by the next command stops taking parameters and the
    // new command's bytes land in ITS block. The pre-fix RTL kept the SYNC capture
    // armed across the command: the CSRW bytes below were eaten as SYNC bytes 2-4 (the
    // master's raster geometry, the slave's graphics window) and CSRR answered the old
    // cursor. [source: NP2kai io/gdc.c gdc_work]
    write_io(8'h62, 8'h0F);       // master SYNC ON ...
    write_io(8'h60, 8'h10);       // ... two of its eight bytes (defsyncm24's own)
    write_io(8'h60, 8'h4E);
    write_io(8'h62, 8'h49);       // CSRW interrupts it
    write_io(8'h60, 8'h56);
    write_io(8'h60, 8'h78);
    write_io(8'h60, 8'h01);
    write_io(8'h62, 8'hE0);       // CSRR
    read_io(8'h62, value); check("sync_abort_master_csrw_lo", {8'h00, value}, 16'h0056);
    read_io(8'h62, value); check("sync_abort_master_csrw_hi", {8'h00, value}, 16'h0078);
    read_io(8'h62, value); check("sync_abort_master_csrw_b2", {8'h00, value}, 16'h0001);
    check("sync_abort_master_sync2_kept", {8'h00, dut.u_crtc.sync_live[2]}, 16'h0007);
    check("sync_abort_master_sync3_kept", {8'h00, dut.u_crtc.sync_live[3]}, 16'h0025);
    check("sync_abort_master_sync4_kept", {8'h00, dut.u_crtc.sync_live[4]}, 16'h0007);
    write_io(8'hA2, 8'h0F);       // slave SYNC ON ...
    write_io(8'hA0, 8'h06);       // ... two of its eight bytes
    write_io(8'hA0, 8'h26);
    write_io(8'hA2, 8'h49);       // CSRW interrupts it
    write_io(8'hA0, 8'h9A);
    write_io(8'hA0, 8'hBC);
    write_io(8'hA0, 8'h02);
    // Five more bytes after the CSRW: on the pre-fix tree these complete the stale
    // SYNC capture and land in the graphics window (AL/VBP).
    write_io(8'hA2, 8'h4A);       // MASK
    write_io(8'hA0, 8'h11);
    write_io(8'hA0, 8'h22);
    write_io(8'hA2, 8'hE0);       // CSRR
    read_io(8'hA2, value); check("sync_abort_slave_csrw_lo", {8'h00, value}, 16'h009a);
    read_io(8'hA2, value); check("sync_abort_slave_csrw_hi", {8'h00, value}, 16'h00bc);
    read_io(8'hA2, value); check("sync_abort_slave_csrw_b2", {8'h00, value}, 16'h00f2);
    check("sync_abort_slave_al_kept",  {6'd0, dut.u_gdc2.gdc2_sal},  16'h0190);
    check("sync_abort_slave_vbp_kept", {10'd0, dut.u_gdc2.gdc2_svbp}, 16'd25);
    check("sync_abort_slave_mask_lo", {8'h00, dut.u_gdc2.gdc2_mask[0]}, 16'h0011);
    check("sync_abort_slave_mask_hi", {8'h00, dut.u_gdc2.gdc2_mask[1]}, 16'h0022);

    // ==== FF2 dat 0x40/0x41 and 0x80/0x81 are NOT write-protected ===========
    // NP2kai gdc_o6a's dat switch sets/clears GDCDISP_PLAZMA for 0x40/0x41 and
    // 0x80/0x81 with no mode2 bit-3 test (only 0x20/0x21 test `gdc.mode2 & 0x08`),
    // and MAME pc9821_video_ff_w protects only dat 4/5 (`((data & 0xfe) == 4) &&
    // !m_ex_video_ff[3]`). The bit reads back through the 0x9A0 query index 5
    // (gdc_ff2_state[6]). FAIL-FIRST: the pre-fix RTL dropped both writes while
    // the write enable was clear.
    write_io(8'h6A, 8'h06);       // write enable OFF
    write_io(8'h6A, 8'h41);
    check("ff2_plazma_set_unprotected", {15'h0, dut.u_crtc.gdc_ff2_state[6]}, 16'h0001);
    write_io(8'h6A, 8'h80);
    check("ff2_plazma_clear_unprotected", {15'h0, dut.u_crtc.gdc_ff2_state[6]}, 16'h0000);
    write_io(8'h6A, 8'h81);
    check("ff2_plazma_set_via_81", {15'h0, dut.u_crtc.gdc_ff2_state[6]}, 16'h0001);
    write_io(8'h6A, 8'h40);
    check("ff2_plazma_clear_via_40", {15'h0, dut.u_crtc.gdc_ff2_state[6]}, 16'h0000);

    // ==== VERDICT ====
    $display("NOTE readback_gdc: %0d cases, %0d mismatched, sim %0t", cases, errors, $time);
    if (errors == 0) begin
      $display("TB_PC9821_READBACK_GDC: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_READBACK_GDC: FAIL (%0d of %0d cases)", errors, cases);
  end

  initial begin
    #800_000_000;
    $fatal(1, "TB_PC9821_READBACK_GDC: TIMEOUT");
  end

endmodule
