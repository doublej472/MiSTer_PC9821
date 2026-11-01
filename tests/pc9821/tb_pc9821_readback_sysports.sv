`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The system-port read-backs, against NP2kai and the machine captures: 0x9A0 is the extended-video INDEX/DATA QUERY (write the index, read the indexed bit; un-written it answers the machine's 0x01), 0x043B round-trips the guest's own bit-2 request on the machine's base byte, the bus mouse's uPD8255 PPI answers its live latches through NP2kai's mode-masked read model (mouseif.c), the printer trio echoes lastData and the strobe latch and carries the one-shot SELECT-BUSY read side effect, 0x11 returns the DMA status register and clears its low nibble on the read, and 0x00BE/0x00BF decode the FDD channel-group media strap instead of floating. 0xA460 reads the board ID 0x40 with the extension-enable bit 0 following the guest's write (0x40 as found, 0x41 once enabled; docs/probes/OPNA.TXT:6).
//
// The system-port read-backs (P1/P4/P8-P13), against
// NP2kai and the machine captures: 0x9A0 is the extended-video INDEX/DATA QUERY
// (write the index, read the indexed bit; un-written it answers the machine's
// 0x01), 0x043B round-trips the guest's own bit-2 request on the machine's base
// byte, the bus mouse's uPD8255 PPI answers its live latches through NP2kai's
// mode-masked read model (mouseif.c), the printer trio echoes lastData and the
// strobe latch and carries the one-shot SELECT-BUSY read side effect, 0x11
// returns the DMA status register and clears its low nibble on the read, and
// 0x00BE/0x00BF decode the FDD channel-group media strap instead of floating.
//
// ---- the bench's own account of where each expectation comes from ----
//
//  1. THE 0x9A0 QUERY PROTOCOL. NP2kai gdc_o9a0/gdc_i9a0 (io/gdc.c:963-1030):
//     a write stores the index and the read returns the indexed bit, with
//     `ret |= (gdc.clock & 2)` in every answer. Two machine captures pin the
//     ends: the un-written read is 0x01 (probes/R10.TXT `09A0=01`, eleven
//     snapshots) and write-0x0A-then-read is 0x00 (probes/PROBE.TXT `FF 9A0
//     after writing 0x0A: 00`), which is exactly the table's index-0x0A answer
//     with analog-256 clear. The old constant answered 0x01 for every index.
//     [source: NP2kai io/gdc.c + docs/probes captures]
//
//  2. 0x043B ECHOES THE LIVE BIT. NP2kai necio_o043b stores `dat & 0x04` and
//     necio_i043b returns it (io/necio.c:24-27); the machine's byte is 0xFB at
//     the DOS prompt after the firmware's own 0x00 writes (hardware-probe-results
//     `0x043B = 0xFB`), so the arm is the machine's base byte with bit 2 live:
//     write 0x04 reads 0xFF and write 0x00 reads 0xFB (the P4 confirm-method's
//     "0xFF/0xFB class"). The constant read 0xFB always.
//     [source: NP2kai io/necio.c + the machine capture]
//
//  3. THE MOUSE PPI. NP2kai mouseif_i7fd9/i7fdb/i7fdd (io/mouseif.c:220-307):
//     Port A composes the buttons with 0x40 and the X nibble while A is an
//     input and echoes the latch when it is an output; Port B answers 0x40
//     while it is an input; Port C returns the latch masked by the mode word
//     (0x93 power-up: C-lower input replaces the low nibble with 0x08 and the
//     three DIP strap bits mouseif.c:296-303 computes from the software-DIP
//     bank - all clear over the measured 0x841E = 0x7C / 0x8E1E = 0x49 image).
//     Writes latch (mouseif_o7fd9/o7fdd/o7fdf include the
//     8255 bit set/reset form); the constants answered 0xE0/0x40/0xF0 whatever
//     the guest wrote. The MODE WRITE resets the Port C latch to 0
//     (mouseif_o7fdf's mode branch ends in setportc(0), mouseif.c:197-216 -
//     the uPD8255 mode-set clears the output latches, which qemu-pc98's
//     hw/input/pc98-mouse.c implements the same way), and the latches' power-up
//     composition is 0xEF: buttons 0xE0 OR the latch_x = -1 reset nibble
//     (mouseif_reset:325-326 - the old 0xE0 pin came from this core's own
//     latch = 0 reset, not from a reference or a capture).
//     [source: NP2kai io/mouseif.c + qemu-pc98 hw/input/pc98-mouse.c]
//
//  4. THE PRINTER TRIO. NP2kai prt_i40/prt_i44 echo the latches and prt_i42
//     carries the SELECT-BUSY one-shot (io/printif.c:44-117): seven consecutive
//     DC1 (0x11) data bytes arm it and the next 0x42 read answers bit 2 CLEAR
//     once. Power-up values are the machine's (`0040 00`, `0044 81`, `0042 94`).
//     [source: NP2kai io/printif.c + docs/probes/PORTS.TXT]
//
//  5. 0x11 IS THE DMA STATUS REGISTER. NP2kai dmac_i11 returns dmac.stat and
//     clears its low nibble on the read (io/dmac.c:290-295). Power-up 0x00 is
//     the machine's (`0011 00`); this core has no DMA engine, so the bench
//     deposits a status byte to observe the clear - the side effect is the
//     contract (P12).
//     [source: NP2kai io/dmac.c + docs/probes/PORTS.TXT]
//
//  6. THE FDD CHANNEL-GROUP REGISTER. The machine reads FF/FF at the power-up strap
//     (docs/probes/FDMODE-XE10.TXT), i.e. `(chgreg & 3) | 0xFC`; NP2kai fdc_ibe's
//     `(chgreg & 3) | 0xF8` (bit 2 clear) is outranked. fdc_obe stores the byte (io/fdc.c:1096-1114,
//     chgreg resets to 3): DOS's FDD driver reads the 2HD/2DD media strap at
//     0x00BE/0x00BF. Undecoded the pair answered open bus 0xFF
//     (P13), the same class as the already-fixed 0x04BE.
//     [source: NP2kai io/fdc.c]
//
// FAIL-FIRST: on the pre-fix tree 0x9A0 answers 0x01 for every index, 0x043B
// answers the constant 0xFB under every write, the mouse ports answer 0xE0/
// 0x40/0xF0 constants (and lose the mode write's Port C reset), the printer
// ports answer 0x00/0x94/0x81 constants (and the DC1 burst never moves 0x42),
// 0x11 is a constant 0x00 that clears nothing, and 0x00BE/0x00BF answer 0xFF.
// The rtlrev-video pass added two capture rows that fail on its pre-fix tree:
// 0x9A0 index 0x0B answered NP2kai's 0x01 where the machine reads 0xFF, and
// 0x9A8 answered a constant 0x00 where the machine round-trips the write
// (docs/probes/RDBACK.TXT).

module tb_pc9821_readback_sysports;
  reg [3:0]  bios_set = 4'd0;      // OSD BIOS set: 0 = PC-9821Xe10 (the default strap)
  // The OSD GDC Clock field (port 0x31 bit 7: 0 = the measured 2.5 MHz strap, 1 = 5 MHz).
  // Static here: this bench is not about the strap and an UNDRIVEN input is 0, which is
  // the machine's own state - tb_pc9821_bios_select and tb_pc9821_userdisk own the field.
  reg  gdc_clock_5m = 1'b0;
  reg  fdd_dip_fixed = 1'b1;   // the 0x00BE bit-2 FDD-mode switch at the measured unit's Fixed
  wire        beep_mute;
  wire [1:0]  beep_vol;   // 0x871E bits [3:2], the beeper volume (see pc9821_iobus)

  reg clk = 0;
  always #5 clk = ~clk;

  reg reset = 1;
  reg triple_fault_reset = 0;
  reg [31:0] cpu_addr = 0, cpu_din = 0;
  reg [3:0]  cpu_be = 0;
  reg        cpu_valid = 0, cpu_write = 0;
  wire [31:0] cpu_dout;
  wire        cpu_ready, cpu_resp_valid;
  reg [7:0]  debug_status = 8'hA5;
  reg        cal_cdat = 0;
  wire [6:0] cfg_ram_mib = 7'd0;
  wire       cfg_seed_en = 1'b0;
  reg [7:0]  device_io_dout = 8'hC3;
  reg        device_rd_wait = 1'b0;
  reg        egc_gate = 1'b0;
  // The 0x9A0 query state pc9821_crtc exports in the real design; driven by
  // hand here so the PROTOCOL (index latch + table + the clock-bit OR) is
  // pinned against NP2kai's gdc_i9a0 table bit for bit.
  reg [10:0] gdc_ff2_state = 11'd0;
  wire       sdip_seed_pulse;   // the machine-reset seed's one-shot (pc9821_iobus)
  wire        device_io_wr, device_io_rd;
  wire [15:0] device_io_addr;
  wire  [7:0] device_io_din;
  wire  [3:0] top_bank;
  wire        sound_extend;
  wire  [7:0] win0_sel;
  wire       win0_sel_moved;   // pc9821_iobus's registered `win0_sel != 8'h08`
  wire sys16m_en;
  wire        ide_rom_enable, bios_ram_gate, a20_enable, cpu_reset_req;
  wire ide_ram_gate;   // 0x1E8E's IDE work-RAM gate (the iobus drives it; unused here)
  wire [15:0] unmapped_writes, unmapped_reads, last_unmapped_port;
  wire  [7:0] post_code;
  wire        post_write;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg, egc_sft, egc_leng;
  wire        egc_shift_we;
  wire  [3:0] dbg_gate;
  wire  [7:0] dbg_itf_stage;
  wire [15:0] dbg_artic_hi;
  wire [15:0] dbg_last_io_addr;
  wire  [7:0] dbg_last_io_data;
  wire        dbg_last_io_rd;
  wire        dbg_last_io_wr;
  // The FDC's debug taps: named because the DUT is (.*), not exercised here
  // (tb_pc9821_fdc_dbg pins them).
  wire [7:0]  dbg_fdc_state;
  wire [7:0]  dbg_fdc_cmd;
  wire [31:0] dbg_fdc_result;
  wire [31:0] dbg_fdc_chrn;
  // The core's native whole-L1 flush handshake (iobus's cache_flush_req /
  // cache_flush_busy / cache_flush_done), modelled here at ZERO LATENCY: this
  // bench does not measure flush timing, and an unmodelled cache_flush_done
  // would leave any flush-triggering write waiting in iobus's S_FLUSH forever.
  // The real request/done contract is tb_pc9821_cache_flush's subject.
  wire cache_flush_req;
  wire crt31k;   // 0x09A8 bit 0 (pc9821_iobus), named so .* binds it
  wire cache_flush_busy = 1'b0;
  wire cache_flush_done = cache_flush_req;

  wire [1:0] ems_state;
  wire top_shadow_en;
  wire        fdc_irq;
  wire        fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window

  reg device_rd_hold = 1'b0;
  reg device_wr_wait = 1'b0;
  // The bus mouse's IRQ13 line and hps_io's parsed mouse packet - the ports
  // pc9821_iobus carries for pc9821_mouse; not exercised by this bench.
  wire        mouse_irq;
  reg  [24:0] ps2_mouse = 25'd0;
  // ---- pc9821_iobus's Phase-1 port groups, tied off: this bench drives NO floppy ----
  // The wildcard instantiation connects every port by name, so the floppy media seam and
  // the uPD71071's bus-master port need a signal here even though nothing in this bench
  // uses them (tools/check_wiring.py requires exactly that). With `fdd_present` clear the
  // FDC never takes its media path, so the data path this seam feeds is unreachable.
/* verilator lint_off UNUSEDSIGNAL */
  wire [3:0]  fdd_present = 4'd0;
  wire [3:0]  fdd_chg = 4'd0;          // no media change: the FDC's ready-change tag
  wire        fdd_frame_tick = 1'b0;
  wire        fdd_req, fdd_req_hdr, fdd_adv;
  wire [1:0]  fdd_unit;
  wire [7:0]  fdd_c, fdd_h, fdd_r, fdd_n, fdd_idx, fdd_dout, fdd_hr, fdd_hn, fdd_hs;
  wire [7:0]  fdd_tc;   // pc9821_iobus's physical-track pair (pc9821_fdc media_tc/media_hd)
  wire        fdd_hd;
  wire        fdd_mf;
  wire        fdd_2hd;   // pc9821_iobus's media-mode pair (pc9821_fdc media_2hd/media_rpm)
  wire        fdd_rpm;
  wire        fdd_ready = 1'b1, fdd_rdy = 1'b0, fdd_hdrv = 1'b0, fdd_err = 1'b0;
  wire [31:0] dma_mem_addr, dma_mem_din;
  wire [1:0]  dma_mem_gvwin;   // the DMAC's plane-window class (unused here)
  wire [3:0]  dma_mem_be;
  wire        dma_mem_req, dma_mem_we;
  wire        dma_mem_ready = 1'b0;
  wire [31:0] dma_mem_dout = 32'd0;
  wire        dma_mem_resp_valid = 1'b0;
/* verilator lint_on UNUSEDSIGNAL */
  // ==== DUT ====
  // Stage A's write-protect seam. Declared because pc9821_iobus is instantiated with `.*`
  // here, which requires every one of its ports to resolve (tools/check_wiring.py).
  wire [3:0] fdd_wp = 4'b0000;
  wire       fdd_req_wr;   // pc9821_iobus's write leg (unused here: no write is issued)
  wire [7:0] fdd_din;
  wire       fdd_abort;

  wire [1:0] d8_bank;   // 0x063C bits 1-0 (the 0xD8000 bank select); unused here

  // P5: the device-bus chip selects are pc9821_iobus outputs now (its own one decode).
  // This bench drives no device select of its own, so they are named here for the wildcard
  // instantiation and left unused.
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) dut (
      .ide_unit0_present(1'b0),.*);

  integer errors = 0, cases = 0;

  // ==== CHECKS ====
  task automatic wr(input [15:0] portnum, input [7:0] data);
    reg [1:0] lane;
    begin
      lane = portnum[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, portnum[15:2], 2'b00};
      cpu_be = 4'b0001 << lane;
      cpu_din = {24'd0, data} << (lane * 8);
      cpu_write = 1;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  task automatic rd1(input [15:0] portnum, output [7:0] data);
    reg [1:0] lane;
    begin
      lane = portnum[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, portnum[15:2], 2'b00};
      cpu_be = 4'b0001 << lane;
      cpu_write = 0;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      #1;
      data = cpu_dout[{lane, 3'b000} +: 8];
      @(negedge clk);
      cpu_valid = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  task automatic rd_is(input [15:0] portnum, input [7:0] want, input [8*72-1:0] what);
    reg [7:0] got;
    begin
      cases = cases + 1;
      rd1(portnum, got);
      if (got !== want) begin
        $display("MISMATCH %0s: port %04x read %02x, expected %02x", what, portnum, got, want);
        errors = errors + 1;
      end
      else $display("ok       %0s = %02x", what, got);
    end
  endtask

  initial begin
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);

    // ==== P1: 0x9A0 is the extended-video index/query =====================
    // Un-written: the machine's 0x01 (the power-up index is unmeasured).
    rd_is(16'h09A0, 8'h01, "P1 un-written answers the machine's 01");
    // The table, bit for bit (state = 0 here): every index answers its bit.
    // 0xA460 reads the board ID 0x40 with the extension-enable bit (bit 0) as the guest set it:
    // `0xA460 (board ID | extension enable bit 0): 40 40` as found (docs/probes/OPNA.TXT:6); the bit follows
    // the guest's own write (the register is the extension gate the same capture names).
    rd_is(16'hA460, 8'h40, "A460 as found = board ID 0x40, extension clear");
    wr(16'hA460, 8'h01); rd_is(16'hA460, 8'h41, "A460 after enabling the extension = 0x41");
    wr(16'hA460, 8'h00); rd_is(16'hA460, 8'h40, "A460 after clearing it = 0x40");
    wr(16'h09A0, 8'h00); rd_is(16'h09A0, 8'hFF, "P1 index 0 answers FF");
    wr(16'h09A0, 8'h01); rd_is(16'h09A0, 8'h00, "P1 index 1 = mode1[1], clear");
    wr(16'h09A0, 8'h02); rd_is(16'h09A0, 8'h00, "P1 index 2 = mode1[4], clear");
    wr(16'h09A0, 8'h03); rd_is(16'h09A0, 8'h00, "P1 index 3 = mode1[7], clear");
    wr(16'h09A0, 8'h04); rd_is(16'h09A0, 8'h00, "P1 index 4 = mode2[0], clear");
    wr(16'h09A0, 8'h05); rd_is(16'h09A0, 8'h00, "P1 index 5 = PLAZMA, clear");
    wr(16'h09A0, 8'h06); rd_is(16'h09A0, 8'h00, "P1 index 6 is unlisted: 0");
    wr(16'h09A0, 8'h07); rd_is(16'h09A0, 8'h00, "P1 index 7 = mode2[2], clear");
    wr(16'h09A0, 8'h08); rd_is(16'h09A0, 8'h00, "P1 index 8 = mode2[3], clear");
    wr(16'h09A0, 8'h09); rd_is(16'h09A0, 8'h00, "P1 index 9 = clock[0], clear");
    wr(16'h09A0, 8'h0A); rd_is(16'h09A0, 8'h00, "P1 index 0x0A = analog-256, clear (the machine's write-then-read 00)");
    // Index 0x0B is NOT NP2kai's constant-1 bit on this machine: the Xe10 reads 0xFF
    // there (docs/probes/RDBACK.TXT `port=09A0 before=01 wrote=0B after=FF back=00`; the
    // same row's `back=00` is the index-1 answer, so the protocol was live). The capture
    // outranks NP2kai gdc_i9a0's `case 0x0b: ret = 1`.
    wr(16'h09A0, 8'h0B); rd_is(16'h09A0, 8'hFF, "P1 index 0x0B reads FF on the machine (RDBACK.TXT)");
    wr(16'h09A0, 8'h01); rd_is(16'h09A0, 8'h00, "P1 RDBACK.TXT's restore: index 1 reads back=00");
    wr(16'h09A0, 8'h0C); rd_is(16'h09A0, 8'h00, "P1 index 0x0C is unlisted: 0");
    wr(16'h09A0, 8'h0D); rd_is(16'h09A0, 8'h00, "P1 index 0x0D = analog-256E, clear");
    // ...and it is a QUERY: the same index answers the BIT, not a constant.
    // State bits 0, 3, 9, 10 set (mode1[1], mode2[0], analog-256, analog-256E):
    // 0x609. gdc.clock bit 1 (bit 8) stays clear here.
    gdc_ff2_state = 11'h609;
    wr(16'h09A0, 8'h01); rd_is(16'h09A0, 8'h01, "P1 index 1 follows mode1[1] live");
    wr(16'h09A0, 8'h02); rd_is(16'h09A0, 8'h00, "P1 index 2 follows mode1[4] live");
    wr(16'h09A0, 8'h04); rd_is(16'h09A0, 8'h01, "P1 index 4 follows mode2[0] live");
    wr(16'h09A0, 8'h0A); rd_is(16'h09A0, 8'h01, "P1 index 0x0A follows analog-256 live");
    wr(16'h09A0, 8'h0D); rd_is(16'h09A0, 8'h01, "P1 index 0x0D follows analog-256E live");
    // gdc.clock bit 1 ORs into EVERY answer (NP2kai `ret |= (gdc.clock & 2)`).
    gdc_ff2_state = 11'h100;
    wr(16'h09A0, 8'h01); rd_is(16'h09A0, 8'h02, "P1 clock bit 1 ORs into the answer");
    wr(16'h09A0, 8'h0A); rd_is(16'h09A0, 8'h02, "P1 clock bit 1 with the indexed bit clear");
    wr(16'h09A0, 8'h00); rd_is(16'h09A0, 8'hFF, "P1 index 0 stays FF under the clock bit");
    gdc_ff2_state = 11'd0;

    // ==== 0x9A8: a LATCH, not a constant (todo item 3) =====================
    // The machine reads 00, then 01 after writing 01, then 00 after the restore
    // (docs/probes/RDBACK.TXT `port=09A8 before=00 wrote=01 after=01 back=00`).
    // NP2kai gdc_o9a8/gdc_i9a8 (SUPPORT_CRT31KHZ) keep bit 0 only: `return((gdc.display
    // >> GDCDISP_31) & 1)`, so a write of 0xFF reads 0x01 there (the machine has not been
    // asked about the high bits - the item's open width question).
    rd_is(16'h09A8, 8'h00, "9A8 power-up reads 00 (RDBACK.TXT before=00)");
    wr(16'h09A8, 8'h01); rd_is(16'h09A8, 8'h01, "9A8 write 01 reads 01 (RDBACK.TXT after=01)");
    wr(16'h09A8, 8'h00); rd_is(16'h09A8, 8'h00, "9A8 restore 00 reads 00 (RDBACK.TXT back=00)");
    wr(16'h09A8, 8'hFF); rd_is(16'h09A8, 8'h01, "9A8 keeps bit 0 only (NP2kai gdc_i9a8)");
    wr(16'h09A8, 8'h00);

    // ==== P4: 0x043B echoes the live bit-2 request ========================
    // The firmware writes 0x00 (hole on); the machine reads 0xFB there.
    wr(16'h043B, 8'h00);
    rd_is(16'h043B, 8'hFB, "P4 write 00 reads FB (the machine's byte)");
    wr(16'h043B, 8'h04);
    rd_is(16'h043B, 8'hFF, "P4 write 04 reads FF: bit 2 round-trips");
    wr(16'h043B, 8'hFB);   // bit 2 clear among others
    rd_is(16'h043B, 8'hFB, "P4 RMW: the read returns the state written");
    wr(16'h043B, 8'h00);
    rd_is(16'h043B, 8'hFB, "P4 ...and back again");

    // ==== P8/P9: the bus mouse's uPD8255 PPI ==============================
    // Power-up (NP2kai mouseif_reset: mode 0x93, portc 0xF0, latch -1):
    // Port A composes to 0xEF (buttons 0xE0 | the latch -1 high nibble 0xF),
    // Port B answers 0x40, Port C reads 0xF8 (0xF0 upper | 0x08 | the three
    // strap bits mouseif.c:296-303 computes from the software-DIP bank - all
    // three clear over the measured power-up image 0x841E = 0x7C /
    // 0x8E1E = 0x49), the control word 0xFF.
    rd_is(16'h7FD9, 8'hEF, "P9 porta power-up composition (latch -1 nibble)");
    rd_is(16'h7FDB, 8'h40, "P8 portb power-up (B is an input)");
    rd_is(16'h7FDD, 8'hF8, "P8 portc power-up is the masked latch | 0x08 | strap 0");
    rd_is(16'h7FDF, 8'hFF, "P8 control word reads open bus");
    // Port C is LIVE: the latch's high nibble round-trips (C-lower is an input,
    // so the low nibble is the strap byte 0x08).
    wr(16'h7FDD, 8'h00);
    rd_is(16'h7FDD, 8'h08, "P8 portc echoes the latch high nibble");
    wr(16'h7FDD, 8'hA5);
    rd_is(16'h7FDD, 8'hA8, "P8 ...with the input nibble replaced");
    wr(16'h7FDD, 8'hFF);
    rd_is(16'h7FDD, 8'hF8, "P8 the firmware's own 7FDD=FF reads the latch | strap");
    // The mode word moves the read model: 0x82 makes Port A an output, so 0x7FD9
    // echoes the porta latch; 0x80 makes C an output too, so 0x7FDD is verbatim.
    // AND the mode write resets the Port C latch to 0 (mouseif_o7fdf's mode
    // branch calls setportc(0), mouseif.c:197-216), so the verbatim read after
    // it is 0x00 and not the 0xFF written before.
    wr(16'h7FD9, 8'h5A);
    wr(16'h7FDF, 8'h82);   // A output, C-lower output, C-upper output, B input
    rd_is(16'h7FD9, 8'h5A, "P9 porta latch echoes while A is an output");
    rd_is(16'h7FDD, 8'h00, "P8 the mode write reset the Port C latch");
    wr(16'h7FDF, 8'h80);   // B output as well
    wr(16'h7FDB, 8'h77);
    rd_is(16'h7FDB, 8'h77, "P8 portb latch echoes while B is an output");
    // The 8255 bit set/reset form (0x7FDF bit 7 clear) moves Port C bit 7 and
    // feeds the same setportc edge (from the reset latch 0x00 here).
    wr(16'h7FDF, 8'h0F);   // set bit 7
    rd_is(16'h7FDD, 8'h80, "P8 BSR set bit 7");
    wr(16'h7FDF, 8'h0E);   // reset bit 7
    rd_is(16'h7FDD, 8'h00, "P8 BSR reset bit 7");
    wr(16'h7FDF, 8'h93);   // back to the firmware's mode (and its setportc(0))
    rd_is(16'h7FDD, 8'h08, "P8 the mode word restores the masked read");
    rd_is(16'h7FD9, 8'hE0, "P9 and the composed Port A answer");

    // ==== P10/P11: the printer trio =======================================
    rd_is(16'h0040, 8'h00, "P10 0x40 power-up is the machine's 00");
    rd_is(16'h0044, 8'h81, "P10 0x44 power-up is the machine's 81");
    rd_is(16'h0042, 8'h94, "P11 0x42 power-up is the machine's 94");
    wr(16'h0040, 8'h5A);
    rd_is(16'h0040, 8'h5A, "P10 0x40 echoes lastData");
    wr(16'h0044, 8'h21);
    rd_is(16'h0044, 8'h21, "P10 0x44 echoes the strobe latch");
    // The SELECT-BUSY one-shot (NP2kai prt_o40/prt_i42): seven consecutive DC1
    // bytes arm it and the next 0x42 read answers bit 2 CLEAR once. The counter
    // only resets on a NON-DC1 byte (prt_o40's else arm), so every run starts
    // with one.
    wr(16'h0040, 8'h00);
    wr(16'h0040, 8'h11); wr(16'h0040, 8'h11); wr(16'h0040, 8'h11);
    wr(16'h0040, 8'h11); wr(16'h0040, 8'h11); wr(16'h0040, 8'h11);
    rd_is(16'h0042, 8'h94, "P11 six DC1s do not arm the busy");
    wr(16'h0040, 8'h11);
    rd_is(16'h0042, 8'h90, "P11 the seventh arms it: one read of bit 2 clear");
    rd_is(16'h0042, 8'h94, "P11 ...and the busy is a one-shot");
    // A non-DC1 byte resets the run: 6 | 0x00 | 6 never reaches the seventh.
    wr(16'h0040, 8'h00);
    wr(16'h0040, 8'h11); wr(16'h0040, 8'h11); wr(16'h0040, 8'h11);
    wr(16'h0040, 8'h11); wr(16'h0040, 8'h11); wr(16'h0040, 8'h11);
    wr(16'h0040, 8'h00);
    wr(16'h0040, 8'h11); wr(16'h0040, 8'h11); wr(16'h0040, 8'h11);
    wr(16'h0040, 8'h11); wr(16'h0040, 8'h11); wr(16'h0040, 8'h11);
    rd_is(16'h0042, 8'h94, "P11 a non-DC1 byte resets the run");

    // ==== P12: 0x11 is the DMA status register with a read side effect ====
    rd_is(16'h0011, 8'h00, "P12 0x11 power-up is the machine's 00");
    // Deposit a terminal-count nibble to observe the CLEAR THE READ performs. The register
    // is the real engine's now (pc9821_dmac, instantiated in pc9821_iobus), so the deposit
    // addresses ITS stat field - the same byte the port answers.
    dut.u_dma.stat = 8'h9B;
    rd_is(16'h0011, 8'h9B, "P12 0x11 returns dmac.stat");
    rd_is(16'h0011, 8'h90, "P12 ...and the read cleared its low nibble");

    // ==== P13: 0x00BE/0x00BF FDD channel-group media strap ================
    // The machine reads FF at the power-up strap (docs/probes/FDMODE-XE10.TXT PORT 00BE=FF,
    // PORT 00BF=FF): bits 7:2 one, bits 1:0 the strap.
    rd_is(16'h00BE, 8'hFF, "P13 0xBE power-up: chgreg 3 -> FF (FDMODE-XE10.TXT)");
    rd_is(16'h00BF, 8'hFF, "P13 0xBF is the same register (FDMODE-XE10.TXT)");
    wr(16'h00BE, 8'h01);
    rd_is(16'h00BE, 8'hFD, "P13 the write lands: (1 & 3) | FC");
    wr(16'h00BF, 8'h02);
    rd_is(16'h00BE, 8'hFE, "P13 the pair is one register (2 & 3) | FC");
    wr(16'h00BE, 8'hFB);
    rd_is(16'h00BE, 8'hFF, "P13 only the low two bits read back (a written bit 2 = 0 still reads 1)");
    // The read is decoded traffic: it must not count as unmapped.
    if (last_unmapped_port == 16'h00BE || last_unmapped_port == 16'h00BF) begin
      $display("MISMATCH P13: a decoded port is the last unmapped port");
      errors = errors + 1;
    end

    // ==== P14: the uPD71071's BANK and BOUND registers ===================
    // The machine's write-then-read round-trips (probes/RDBACK.TXT:153-157):
    //     port=0021 before=00 wrote=A5 after=05 back=00
    //     port=0023 before=00 wrote=A5 after=05 back=00
    //     port=0025 before=0E wrote=A5 after=05 back=0E
    //     port=0027 before=00 wrote=A5 after=05 back=00
    //     0029 bound selector before=00 after 04/08/0C = 01 02 03
    // So 0x21/0x23/0x25/0x27 are LIVE LATCHES (the machine reads back a byte it
    // can only have latched: 0xA5 -> 0x05 on all four), not the constants they
    // were, and each keeps its own byte. The nibble is `dat & 0x0f` - the
    // CAPTURE IS THE ONLY SOURCE for the NIBBLE WIDTH: NP2kai's compiled
    // PC-9821 branch (CPUCORE_IA32) stores the bank byte UNMASKED
    // (io/dmac.c:236-237), and the `dat & 0x0f` line the audit quoted
    // (dmac.c:239-241) sits in the non-compiled 20-bit-V30 branch.
    //
    // THE CHANNEL MAP AND 0x29'S STORE ARE NOT THE MACHINE'S TO DECIDE - the
    // capture cannot see either (all four bank writes carry the same byte, and
    // all three bound writes carry `dat & 3 == 0`). They come from the two
    // software references and this core's own engine, which agree three ways:
    //   * bank: NP2kai `((port >> 1) + 1) & 3` (io/dmac.c:236-237) => 0x21 is
    //     channel 1 and 0x27 is channel 0; qemu the same formula, stated as a
    //     contract in its header (`hw/dma/pc98-dma.c:6,269-272`); our own
    //     pc9821_dmac.sv:213 `cpu_bank_ch = idx[1:0] + 2'd1`. Each port reads its own channel, so the
    //     rotation is invisible here and is checked in tb_pc9821_dma_regs at the array.
    //   * bound: NP2kai stores per channel (`dmach = dmac.dmach + (dat & 3);
    //     dmach->bound = (dat >> 2) & 3`, io/dmac.c:260-263) and so does qemu
    //     (`regs[data & 3].bank_wrap`), NOT one global latch; the read exposes
    //     CHANNEL 0 alone (pc9821_dmac.sv:557 `ch_bound[0]`, and 0x29 has no read handler in
    //     either reference). Both models return the same bytes for the capture's
    //     three writes (all channel 0) - the rows below are what separates them.
    // The bytes below are now THE ENGINE'S (pc9821_dmac) at reset, which is what the
    // register file answers once the stub is gone. The 0x25 = 0x0E row was the DOS PROMPT's
    // as-found byte (one sample, RDBACK + PORTS.TXT:170) and the stub seeded it because it
    // had no engine to reproduce the boot traffic that left it; the engine exists now, but
    // the traffic still does not - a core with no guest DOS cannot replay the channel
    // programming that put 0x0E there, and seeding a chip register to a guest-programmed
    // value would be the untrue thing. The LATCH was the capture-proven part, and the latch
    // is what is still here, one level down.
    rd_is(16'h0021, 8'h00, "P14 0x21 at reset");
    rd_is(16'h0023, 8'h00, "P14 0x23 at reset");
    rd_is(16'h0025, 8'h00, "P14 0x25 at reset (the DOS-prompt 0E is guest traffic)");
    rd_is(16'h0027, 8'h00, "P14 0x27 at reset");
    rd_is(16'h0029, 8'h00, "P14 0x29 as found at the DOS prompt");
    // The capture's own sequence: writing A5 to each port reads 05 back.
    wr(16'h0021, 8'hA5); rd_is(16'h0021, 8'h05, "P14 0x21 wrote A5 reads 05");
    wr(16'h0023, 8'hA5); rd_is(16'h0023, 8'h05, "P14 0x23 wrote A5 reads 05");
    wr(16'h0025, 8'hA5); rd_is(16'h0025, 8'h05, "P14 0x25 wrote A5 reads 05");
    wr(16'h0027, 8'hA5); rd_is(16'h0027, 8'h05, "P14 0x27 wrote A5 reads 05");
    rd_is(16'h0021, 8'h05, "P14 the four are separate latches (0x21 unchanged)");
    rd_is(16'h0025, 8'h05, "P14 ...and 0x25 kept its own byte");
    // The latch is FOUR BITS wide (the capture's nibble): the high nibble of a
    // write does not reach the read.
    wr(16'h0021, 8'hF0); rd_is(16'h0021, 8'h00, "P14 write F0 reads 00: high nibble dropped");
    wr(16'h0021, 8'hFF); rd_is(16'h0021, 8'h0F, "P14 write FF reads 0F");
    wr(16'h0021, 8'h0B); rd_is(16'h0021, 8'h0B, "P14 write 0B reads 0B (low nibble kept)");
    // 0x29 is the BOUND selector, `(dat >> 2) & 3` stored in the channel `dat & 3`
    // selects, with CHANNEL 0 ALONE on the read: the capture's 04/08/0C -> 01/02/03
    // (all three select channel 0, which is why the capture cannot separate the
    // per-channel store from one global latch - see the block above).
    wr(16'h0029, 8'h04); rd_is(16'h0029, 8'h01, "P14 0x29 write 04 reads 01 (the machine's row)");
    wr(16'h0029, 8'h08); rd_is(16'h0029, 8'h02, "P14 0x29 write 08 reads 02 (the machine's row)");
    wr(16'h0029, 8'h0C); rd_is(16'h0029, 8'h03, "P14 0x29 write 0C reads 03 (the machine's row)");
    // A selector that is not 0 lands on ANOTHER channel and cannot move the byte
    // 0x29 returns. FAIL-FIRST against the one-latch model: it read the LAST write's
    // value, so write 03 read 00 and write 7F read 03 where both rows below want 03
    // and 00.
    wr(16'h0029, 8'h03); rd_is(16'h0029, 8'h03, "P14 0x29 write 03 selects ch3: ch0 still reads 03");
    wr(16'h0029, 8'h00); rd_is(16'h0029, 8'h00, "P14 0x29 write 00 selects ch0: the field is cleared");
    wr(16'h0029, 8'h7F); rd_is(16'h0029, 8'h00, "P14 0x29 write 7F selects ch3: ch0 stays 00 (a global latch reads 03)");
    // A channel-0 write stores `(dat >> 2) & 3` and only that: 0xFC stores 3, not 0x3F,
    // so bits 7:4 are not part of the field.
    wr(16'h0029, 8'hFC); rd_is(16'h0029, 8'h03, "P14 0x29 write FC reads 03 (bits 7:4 are not stored)");
    // The neighbours stay open bus: the new arms must not widen the decode.
    // probes/PORTS.TXT:169-172 `0024$FF`, `0026&FF`, `0028(FF`, `002A*FF`.
    rd_is(16'h0024, 8'hFF, "P14 0x24 stays open bus");
    rd_is(16'h0026, 8'hFF, "P14 0x26 stays open bus");
    rd_is(16'h0028, 8'hFF, "P14 0x28 stays open bus");
    rd_is(16'h002A, 8'hFF, "P14 0x2A stays open bus");
    // 0x1B (MASTER CLEAR, a driven 0x00 - the machine's own byte) is untouched
    // by this work; the bench's section above owns it.

    // ==== P15: 0x610 is the ITF's POST-stage latch, WRITE-ONLY to the guest ===
    // probes/RDBACK.TXT:161: `port=0610 before=FF wrote=1A after=FF back=FF`.
    // The probe wrote a stage byte the latch demonstrably takes (the ITF's own
    // writes reach it, see the dbg_itf_stage check below) and the guest read
    // still answered open bus both before and after, so 0x610's read is 0xFF.
    // The LATCH stays: it is the watchdog's U= POST-stage field (dbg_itf_stage)
    // and it is kept for exactly that. NP2kai has no handler at all
    // there, so it answers its define-default 0xFF too - both references agree
    // with the capture here.
    rd_is(16'h0610, 8'hFF, "P15 0x610 reads open bus FF at reset");
    wr(16'h0610, 8'h1A);
    rd_is(16'h0610, 8'hFF, "P15 ...and FF after writing 1A (the machine's capture)");
    rd_is(16'h0610, 8'hFF, "P15 ...and FF on the re-read");
    if (dbg_itf_stage !== 8'h1A) begin
      $display("MISMATCH P15: 0x610's latch did not reach the telemetry: dbg_itf_stage=%02x",
               dbg_itf_stage);
      errors = errors + 1;
    end
    else $display("ok       P15 0x610's write still moves dbg_itf_stage = %02x", dbg_itf_stage);

    // ==== VERDICT ====
    $display("NOTE readback_sysports: %0d cases, %0d mismatched, sim %0t", cases, errors, $time);
    if (errors == 0) begin
      $display("TB_PC9821_READBACK_SYSPORTS: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_READBACK_SYSPORTS: FAIL (%0d of %0d cases)", errors, cases);
  end

  // In-bench watchdog: a bench that blocks on a DUT signal with no bound hangs CI.
  initial begin
    #4_000_000;
    $fatal(1, "TB_PC9821_READBACK_SYSPORTS: TIMEOUT");
  end

endmodule
