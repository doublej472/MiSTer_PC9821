`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PRAM:
// The PC-9821's battery-backed BIOS settings store -- the two-bank software-DIP switch at 0x841E-0x8F1E with its 0x8F1F address/control latch -- against NP2kai's io/dipsw.c and qemu-pc98, with the machine's own captures deciding where they disagree (docs/probes/PORTS.TXT's read-only sweep and docs/probes/RDBACK.TXT:162, the one write-then-read round): the power-up image is the measured bank A, the latch selects bank A (the twelve data ports 0x841E-0x8F1E) or bank B (12..23, off by +12 and not +16), a write stores the guest byte verbatim except 0x84's bit 1 (the one unmeasured strap) - the bench used to MASK each register's PARITY bit too and was inverted here on the machine's evidence, because the firmware writes those bits (BANK3@0xFA219's parity idiom; the ITF's `or al,0x80 / out 0x8E1E`) and the ITF's repair installs its factory tables BANK4@0x480C/0x4818 through these ports, so a frozen parity bit composed its 0x7F over the machine image 0xBF into an EVEN 0xFF - the SET THE SOFTWARE DIP-SWITCH loop (the Xa7C9W capture holds the factory 0x7F at that cell; NP2kai's write mask is OVERRULED by the machine, same adjudication as the read side; the falsifier is probe2 /RDBACK at 0x8B1E/0x881E on the machine), a READ RETURNS THE STORED BYTE VERBATIM (the machine reads back the EVEN-parity 0x0C it wrote at 0x871E, `port=871E before=3E wrote=0C after=0C back=3E`, and qemu-pc98's pc98_sdip_read/pc98_sdip_write store and return it verbatim too, so the capture and qemu agree against NP2kai's odd-parity recompute on read), the authentic ITF's own read-back verifier passes, the MACHINE-RESET strobe RE-SEEDS the store to the power-up image (without a reset path a platform reset leaves whatever the previous run had written, which brings the software-DIP message back; a guest SETUP change therefore does not survive a platform reset any more, where the machine's own battery-backed store would keep it - the deliberate divergence item 94 records), and the ports outside 0x841E-0x8F1E answer open bus. NP2kai's FOUR divergent behaviours on this store -- it treats 0x871E/0x8E1E as PC-9801 control ports, it recomputes an odd-parity bit on every read, it refuses a write whose byte is not already odd-parity, and it masks each register's parity bit on write -- are printed as WAIVED lines rather than asserted, because the machine's own capture reads 0x871E=0x3E and 0x8E1E=0x49 as stored bytes and returns an even-parity write verbatim, which resolves all four for this RTL. And the ITF's own REPAIR is replayed byte for byte (BANK4@0xFC7B2-0xFC8DE: the factory tables out the ports, 0x8B's bit 6 saved and ORed back) and must leave an image the ITF's own predicate accepts and that a second repair cannot move - FAIL-FIRST, because with the old frozen parity bits the install composed EVEN 0x5C/0xFF at 0x881E/0x8B1E over the machine image and the message loop formed.

module tb_pc9821_pram;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;
  reg [31:0] cpu_addr = 0, cpu_din = 0;
  reg [3:0] cpu_be = 0;
  reg cpu_valid = 0, cpu_write = 0;
  wire [31:0] cpu_dout;
  wire cpu_ready, cpu_resp_valid;
  reg [7:0] debug_status = 8'hA5;
  wire device_io_wr, device_io_rd;
  wire [15:0] device_io_addr;
  wire [7:0] device_io_din;
  reg [7:0] device_io_dout = 8'hC3;
  reg       device_rd_wait = 1'b0;
  wire [3:0] top_bank;
  wire sound_extend;
  wire        beep_mute;
  wire [1:0]  beep_vol;   // 0x871E bits [3:2], the beeper volume (see pc9821_iobus)
  wire ide_rom_enable, bios_ram_gate;
  wire ide_ram_gate;   // 0x1E8E's IDE work-RAM gate (the iobus drives it; unused here)
  wire [7:0] win0_sel;
  wire       win0_sel_moved;   // pc9821_iobus's registered `win0_sel != 8'h08`
  wire sys16m_en;
  wire top_shadow_en;
  wire soft_reboot;   // pc9821_iobus's reboot strobe (0x534)
  wire        fdc_irq;
  wire        fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window
  wire a20_enable, cpu_reset_req;
  wire [15:0] unmapped_writes, unmapped_reads, last_unmapped_port;
  wire [7:0] post_code;
  wire post_write;
  // The core's native whole-L1 flush handshake (iobus's cache_flush_req /
  // cache_flush_busy / cache_flush_done), modelled here at ZERO LATENCY: this
  // bench does not measure flush timing, and an unmodelled cache_flush_done
  // would leave any flush-triggering write waiting in iobus's S_FLUSH forever.
  // The real request/done contract is tb_pc9821_cache_flush's subject.
  wire cache_flush_req;
  wire crt31k;   // 0x09A8 bit 0 (pc9821_iobus), named so .* binds it
  wire cache_flush_busy = 1'b0;
  wire cache_flush_done = cache_flush_req;
  wire [3:0] dbg_gate;
  wire [7:0] dbg_itf_stage;
  wire [15:0] dbg_artic_hi;
  wire [15:0] dbg_last_io_addr;
  wire  [7:0] dbg_last_io_data;
  wire        dbg_last_io_rd;
  wire        dbg_last_io_wr;
  wire        dbg_last_io_stb;
  // The FDC's debug taps: named because the DUT is (.*), not exercised here
  // (tb_pc9821_fdc_dbg pins them).
  wire [7:0]  dbg_fdc_state;
  wire [7:0]  dbg_fdc_cmd;
  wire [31:0] dbg_fdc_result;
  wire [31:0] dbg_fdc_chrn;
  reg        cal_cdat = 0;
  wire [6:0] cfg_ram_mib = 7'd0;
  wire       cfg_seed_en = 1'b0;
  wire       sdip_seed_pulse;   // the machine-reset seed's one-shot (pc9821_iobus)
  reg        triple_fault_reset = 1'b0;
  reg        egc_gate = 1'b0;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg,
              egc_sft, egc_leng;
  wire        egc_shift_we;
  wire [1:0] ems_state;

  // ==== DUT ====
  reg device_rd_hold = 1'b0;
  reg [3:0]  bios_set = 4'd0;      // OSD BIOS set: 0 = PC-9821Xe10 (the default strap)
  // The OSD GDC Clock field (port 0x31 bit 7: 0 = the measured 2.5 MHz strap, 1 = 5 MHz).
  // Static here: this bench is not about the strap and an UNDRIVEN input is 0, which is
  // the machine's own state - tb_pc9821_bios_select and tb_pc9821_userdisk own the field.
  reg  gdc_clock_5m = 1'b0;
  reg  msw_hold = 1'b0;        // port 0x31 bit 4 at the measured machine's memory-switch init (0xF3)
  reg  text_lines_20 = 1'b0;   // port 0x31 bit 3 at the measured 25 lines (0xF3)
  // Floppy mode list position 1, 1M: 0x861E = 0x76, the measured bank-A image
  // (docs/probes/PORTS.TXT) this bench reads back. The OSD default, position 0 = Auto (1M),
  // seeds 0xF7 (tb_pc9821_floppy_mode).
  reg  [1:0] floppy_mode = 2'd1;
  wire [23:0] setup_cfg;       // the OSD configuration pc9821_cg is built from (unread here)
  reg device_wr_wait = 1'b0;   // write back-pressure: unused here (no device buffer is stressed), 0 = never stall
  // The 0x9A0 query state input (pc9821_iobus): driven at 0 here - only
  // tb_pc9821_readback_sysports exercises the query protocol.
  reg [10:0] gdc_ff2_state = 11'd0;
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
  wire [31:0] dma_mem_addr_nx;   // the address dma_mem_addr loads next, and its load cycle (unused here)
  wire        dma_mem_load;
  wire [3:0]  dma_mem_be;
  wire        dma_mem_req, dma_mem_we;
  wire        dma_mem_ready = 1'b0;
  wire [31:0] dma_mem_dout = 32'd0;
  wire        dma_mem_resp_valid = 1'b0;
/* verilator lint_on UNUSEDSIGNAL */
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
  // The OSD's I/O timing field (pc9821_iobus io_timing_xe10): Fast, the default table.
  wire io_timing_xe10 = 1'b0;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) dut (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),.*);

  integer errors = 0;
  integer waived = 0;
  integer wchecks = 0;
  reg [7:0] got;

  // ==== STIMULUS ====
  task automatic fail(input [8*100-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // A mismatch the references disagree on, resolved in the RTL's favour by the
  // machine's own capture. Printed, counted, and deliberately not fatal. The port is
  // 160 bytes so a waiver can carry its capture citation (the two RDBACK.TXT rows).
  task automatic waive(input [8*160-1:0] message);
    begin
      $display("WAIVED: %0s", message);
      waived = waived + 1;
    end
  endtask

  task automatic write_byte(input [15:0] portnum, input [7:0] data);
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

  task automatic read_raw(input [15:0] portnum, output [7:0] data);
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

  task automatic read_byte(input [15:0] portnum, input [7:0] expected);
    begin
      read_raw(portnum, got);
      if (got !== expected) begin
        $display("FAIL read %04x got=%02x want=%02x @ %0t", portnum, got, expected, $time);
        errors = errors + 1;
      end
    end
  endtask

  // The odd-parity rule the authentic ITF's verifier demands of every byte it
  // accepts (`test al,0ffh; jpo`, BANK4 0x46C4/0x46E6/0x4702/0x471C).
  function automatic is_odd_parity(input [7:0] v);
    is_odd_parity = ^v;
  endfunction

  // The value a data port RETURNS: the stored byte, verbatim. The core used to
  // force an odd-parity bit on the way out (this bench's old `want_read`), which
  // is NP2kai's model; the machine refutes it at 0x871E, where an EVEN-parity
  // write comes straight back (docs/probes/RDBACK.TXT:162), and qemu-pc98 stores
  // and returns the byte verbatim too (hw/misc/pc98-sys.c pc98_sdip_read /
  // pc98_sdip_write). The straps are not "parity bits": they are the machine's
  // non-writable bits, supplied by the power-up image, and they are already part
  // of the stored byte.
  // The one bit a write does not own: 0x84's bit 1 (NP2kai's unmeasured strap). Every
  // other bit - the per-register PARITY bits (bit 0 of 0x84, bit 4 of 0x85, bit 7 of the
  // rest) included - is stored as written, because the firmware writes those bits
  // (BANK3@0xFA219's parity idiom; the ITF's `or al,0x80 / out 0x8E1E`) and the ITF's
  // repair installs its factory tables through these ports (BANK4@0xFC7E4). See the
  // RTL's sdip_data_mask comment for the adjudication and its falsifier.
  function automatic [7:0] data_mask(input [3:0] idx);
    case (idx)
      4'h0: data_mask = 8'hFD;
      // Bank A 0x851E stores its bit 4 alone; the write's other bits go to port 0x31 (the
      // Xe10: docs/probes/XE10CFG-XE10-CFGWR.TXT `RT 851E was=02 wrote=12 got=12 p31=12`, and
      // 0x851E reads 02 after the ITF's E3 merge, XE10CFG-XE10-CFG0.TXT).
      4'h1: data_mask = 8'h10;
      default: data_mask = 8'hFF;
    endcase
  endfunction

  // The machine's measured bank A (docs/probes/PORTS.TXT, read-only, no writes):
  // "SDIP 841E + n*100 (n=0..15)" -> 7C 02 76 3E 7C 7F FF BF 7F 7F 49 98, then
  // the four ports past 0x8F read 0xFF. This is the one copy of the image here.
  reg [7:0] machine_banka [0:11];
  initial begin
    machine_banka[0]=8'h7C;  machine_banka[1]=8'h02;  machine_banka[2]=8'h76;
    machine_banka[3]=8'h3E;  machine_banka[4]=8'h7C;  machine_banka[5]=8'h7F;
    machine_banka[6]=8'hFF;  machine_banka[7]=8'hBF;  machine_banka[8]=8'h7F;
    machine_banka[9]=8'h7F;  machine_banka[10]=8'h49; machine_banka[11]=8'h98;
  end

  // A behavioural transcription of NP2kai io/dipsw.c's pccore.dipsw[0..2] for
  // the five ports it handles. Seeded with the machine's bank A bytes 0..2 so
  // the comparison is of SEMANTICS, not of independent power-up defaults.
  reg [7:0] np_dipsw [0:2];
  reg [1:0] np_beep_vol;
  task automatic np_reset;
    begin
      np_dipsw[0] = machine_banka[0];
      np_dipsw[1] = machine_banka[1];
      np_dipsw[2] = machine_banka[2];
      np_beep_vol = 2'b00;
    end
  endtask

  // NP2kai writes 0x84/0x85/0x86 into dipsw[0..2]; 0x87 is a control for DSW2
  // bit 4 plus the beep volume; 0x8E is a control for DSW3 bit 7. Every write is
  // gated on the byte it is handed already having odd parity.
  task automatic np_write(input [11:0] port, input [7:0] value);
    reg [7:0] set;
    begin
      if (!is_odd_parity(value)) return;   // iflags[value] & P_FLAG
      case (port[11:8])
        4'h4: np_dipsw[0] = (np_dipsw[0] & 8'h03) | (value & 8'hFC);
        4'h5: np_dipsw[1] = (np_dipsw[1] & 8'h10) | (value & 8'hEF);
        4'h6: np_dipsw[2] = (np_dipsw[2] & 8'h80) | (value & 8'h7F);
        4'h7: begin
                set = (value & 8'h20) >> 1;
                if ((np_dipsw[1] ^ set) & 8'h10) np_dipsw[1] = np_dipsw[1] ^ 8'h10;
                np_beep_vol = (value >> 2) & 2'b11;
              end
        4'hE: begin
                set = (value & 8'h10) << 3;
                if ((np_dipsw[2] ^ set) & 8'h80) np_dipsw[2] = np_dipsw[2] ^ 8'h80;
              end
        default: ;
      endcase
    end
  endtask

  function automatic [7:0] np_read(input [11:0] port);
    reg [7:0] ret;
    begin
      ret = 8'hFF;
      case (port[11:8])
        4'h4: begin ret = np_dipsw[0] & 8'hFC; if (!is_odd_parity(ret)) ret = ret | 8'h01; end
        4'h5: begin ret = np_dipsw[1] & 8'hEF; if (!is_odd_parity(ret)) ret = ret | 8'h10; end
        4'h6: begin ret = np_dipsw[2] & 8'h7F; if (!is_odd_parity(ret)) ret = ret | 8'h80; end
        4'h7: begin ret = ((np_dipsw[1] & 8'h10) << 1) | (np_beep_vol << 2);
                    if (!is_odd_parity(ret)) ret = ret | 8'h80; end
        4'hE: begin ret = (np_dipsw[2] & 8'h80) >> 3;
                    if (!is_odd_parity(ret)) ret = ret | 8'h80; end
        default: ;
      endcase
      np_read = ret;
    end
  endfunction

  // ==== CHECKS ====
  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    np_reset;

    // ---- 1. the store's power-up image and the control port ----------------
    // 0x8F1F is write-only: the machine's read-only sweep records it as 0xFF
    // (docs/probes/PORTS.TXT `8F1F FF`), and NP2kai's defout8/definp8 match only
    // the 0x8X1E data form, so 0x8F1F stays open bus.
    read_byte(16'h8F1F, 8'hFF);
    // Bank A out of reset is the measured machine image, byte for byte. To read
    // it the guest must first open the bank with 0x80 (bit 7) as the ITF does.
    write_byte(16'h8F1F, 8'h80);
    for (integer n = 0; n < 12; n = n + 1)
      read_byte(16'h841E + (n << 8), machine_banka[n]);
    // Every data port carries a byte whose parity is ODD out of reset -- the
    // property the ITF's verifier demands (eleven of twelve by chance is a
    // 1-in-2048 coincidence, so it is a rule and not an accident). The stored
    // image is checked directly here, before any write in this bench.
    for (integer n = 0; n < 12; n = n + 1)
      if (n != 6 && !is_odd_parity(dut.sdip[n]))
        fail("a bank A power-up byte is not odd parity");
    // The four port nibbles past 0x8F are NOT SDIP: the machine reads 0x901E,
    // 0x911E, 0x921E and 0x931E as 0xFF, and `sdip_data_port` stops at 0x8F.
    read_byte(16'h901E, 8'hFF);
    read_byte(16'h911E, 8'hFF);
    // ... and the low-byte form is exact: a port whose low byte is not 0x1E is
    // not the store even inside the nibble range.
    read_byte(16'h841F, 8'hFF);
    // Bank B's power-up image is the ITF's own factory table (BANK4 0x4818: 0x8F
    // then eleven 0x80 bytes, every one odd parity), the same twelve bytes the
    // ITF's write loop loads under 0xC0.
    write_byte(16'h8F1F, 8'hC0);
    read_byte(16'h841E, 8'h8F);
    for (integer n = 1; n < 12; n = n + 1)
      read_byte(16'h841E + (n << 8), 8'h80);
    write_byte(16'h8F1F, 8'h80);

    // ---- 2. the 0x8F1F address/control latch -------------------------------
    // Bit 7 is the write enable and bit 6 the bank select (QEMU pc98-sys.c:505;
    // the ITF opens with 0x80 and latches bank B with 0xC0, BANK4 0x4433/0x4467).
    // A data write with the gate CLOSED is ignored.
    write_byte(16'h8F1F, 8'h00);
    write_byte(16'h841E, 8'h00);
    read_byte(16'h841E, 8'h7C);           // unchanged: the gate is shut
    // Open bank A and write a value; the write takes.
    write_byte(16'h8F1F, 8'h80);
    write_byte(16'h841E, 8'h04);          // bit 2 only, odd data parity
    read_byte(16'h841E, 8'h04);
    // Select bank B with 0xC0 and confirm the SAME port reads the OTHER cell.
    write_byte(16'h8F1F, 8'hC0);
    read_byte(16'h841E, 8'h8F);           // bank B index 0 power-up seed
    // Bank B index 0 starts at 0x8F, so its withheld bit 1 (the one unmeasured strap,
    // NP2kai io/dipsw.c) is SET and is kept; every other bit - bit 0, the register's
    // parity bit, included - is stored as written. A write of 0x0C therefore stores
    // 0x0E. Storing the written byte is what the machine does at the one measured port
    // (`wrote=0C after=0C`, docs/probes/RDBACK.TXT:162) and what the ITF's own repair
    // REQUIRES (BANK4@0xFC7E4 installs BANK4@0x480C/0x4818 through these ports; the
    // Xa7C9W capture holds the factory byte 0x7F at the cell a frozen parity bit
    // trapped). NP2kai masks the parity bit on write and was overruled by the machine.
    write_byte(16'h841E, 8'h0C);
    read_byte(16'h841E, 8'h0E);
    // Bank A kept its own byte: the two banks are separate cells.
    write_byte(16'h8F1F, 8'h80);
    read_byte(16'h841E, 8'h04);
    // Bank B occupies indices 12..23. Concatenating the bank bit onto the index
    // gave index+16, so bank B's 0x8C1E..0x8F1E addressed sdip[24..27], OUTSIDE
    // the 24-byte store; those four ports must answer bank B's 8..11 (0x80).
    write_byte(16'h8F1F, 8'hC0);
    read_byte(16'h8C1E, 8'h80);           // bank B index 8
    read_byte(16'h8D1E, 8'h80);           // bank B index 9
    read_byte(16'h8E1E, 8'h80);           // bank B index 10
    read_byte(16'h8F1E, 8'h80);           // bank B index 11
    // The latch itself is not part of either bank: writing a data port never
    // moves the bank select, so the port above stays on bank B throughout.
    write_byte(16'h8F1F, 8'h80);          // back to bank A

    // ---- 3. read/write and the VERBATIM read -------------------------------
    // For each of the twelve bank A ports, drive a value into the writable bits
    // and require the read to be the STORED byte: the straps keep their power-up
    // values and nothing is recomputed on the way out (the
    // machine's 0x871E round trip in docs/probes/RDBACK.TXT:162). NP2kai's
    // odd-parity recompute, which this bench used to expect, is refuted there.
    begin
      reg [7:0] want, base;
      for (integer n = 0; n < 12; n = n + 1) begin
        // Start from the power-up byte so 0x84's withheld bit 1 stays the machine's.
        base = machine_banka[n];
        // Everything the write owns is stored as written (index 1: bit 4 only).
        want = (base & ~data_mask(n[3:0])) | (8'h55 & data_mask(n[3:0]));
        write_byte(16'h841E + (n << 8), 8'h55);
        read_byte(16'h841E + (n << 8), want);
      end
    end
    // 0x8A (index 6) is the ITF's XOR partner of 0x89 and carries no strap: a
    // write of 0x00 stores and reads 0x00.
    write_byte(16'h8A1E, 8'h00);
    read_byte(16'h8A1E, 8'h00);
    // A zero write clears the writable bits and reads back 0x00 on every port:
    // the read does NOT put an odd-parity bit back. The machine is measured doing
    // this at 0x871E with the even byte 0x0C (RDBACK.TXT:162 `wrote=0C after=0C`).
    write_byte(16'h841E, 8'h00);
    read_byte(16'h841E, 8'h00);
    write_byte(16'h851E, 8'h00);
    read_byte(16'h851E, 8'h02);   // bit 4 cleared; the measured 0x02 data is not the write's
    write_byte(16'h861E, 8'h00);
    read_byte(16'h861E, 8'h00);

    // ---- 4. the authentic ITF's own read-back verifier ---------------------
    // BANK4 0x46BA-0x4726: open bank A, read 0x84..0x88 and 0x8B..0x8F and
    // require odd parity on each (`test al,0xff; jpo`), then read 0x89 and 0x8A
    // and require their XOR to have odd parity, then open bank B and require odd
    // parity on 0x84..0x8D. Replay it through the ports on a fresh image: the
    // RTL must satisfy the firmware's own acceptance test.
    reset = 1;    // the machine-reset seed: the store's only restore now
    repeat (2) @(posedge clk);
    reset = 0;
    while (dut.sdip_seq_active) @(posedge clk);
    @(negedge clk);
    write_byte(16'h8F1F, 8'h80);
    for (integer n = 0; n < 12; n = n + 1) begin
      if (n == 5 || n == 6) continue;
      read_raw(16'h841E + (n << 8), got);
      wchecks = wchecks + 1;
      if (!is_odd_parity(got)) begin
        $display("FAIL ITF verifier: bank A %02x1E read %02x is not odd parity", 8'h84 + n, got);
        errors = errors + 1;
      end
    end
    begin
      reg [7:0] b5, b6;
      read_raw(16'h891E, b5);
      read_raw(16'h8A1E, b6);
      if (!is_odd_parity(b5 ^ b6)) begin
        $display("FAIL ITF verifier: bank A 0x89/0x8A XOR %02x is not odd parity", b5 ^ b6);
        errors = errors + 1;
      end
    end
    write_byte(16'h8F1F, 8'hC0);
    for (integer n = 0; n < 10; n = n + 1) begin
      read_raw(16'h841E + (n << 8), got);
      if (!is_odd_parity(got)) begin
        $display("FAIL ITF verifier: bank B %02x1E read %02x is not odd parity", 8'h84 + n, got);
        errors = errors + 1;
      end
    end
    $display("PRAM ITF verifier replayed: bank A 10 bytes + the 0x89/0x8A XOR pair + bank B 10 bytes, all accepted");
    write_byte(16'h8F1F, 8'h80);

    // ---- 5. the NP2kai differential (primary software reference) -----------
    // The STORE is where NP2kai agrees: its per-port writable mask and its strap
    // preservation match the RTL byte for byte on the three DSW ports
    // 0x84/0x85/0x86, so the comparison below is the RTL's read -- which returns
    // the stored byte verbatim -- against NP2kai's STORED byte, np_dipsw[n]. Only
    // odd-parity bytes are written here, so NP2kai's own write gate
    // (`iflags[value] & 0x04`) is satisfied and the comparison is of a stored
    // byte, not of the gate; the gate itself is the row before section 6.
    begin
      reg [7:0] rtl_read, np;
      // 0x54, 0x7F and 0x01 all have ODD parity. 0x7F is the highest writable
      // data value and 0x01 the lowest; 0x55 is even parity and NP2kai would
      // drop it, which is one of the three divergences below.
      np_reset;
      reset = 1;    // the machine-reset seed: the store's only restore now
      repeat (2) @(posedge clk);
      reset = 0;
      while (dut.sdip_seq_active) @(posedge clk);
      @(negedge clk);
      write_byte(16'h8F1F, 8'h80);
      for (integer n = 0; n < 3; n = n + 1) begin
        for (integer v = 0; v < 3; v = v + 1) begin
          write_byte(16'h841E + (n << 8), v == 0 ? 8'h54 : (v == 1 ? 8'h7F : 8'h01));
          np_write(16'h841E + (n << 8), v == 0 ? 8'h54 : (v == 1 ? 8'h7F : 8'h01));
          read_raw(16'h841E + (n << 8), rtl_read);
          // 0x851E's data bits are port 0x31's on the Xe10 (CFGWR.TXT `wrote=12 p31=12`), which
          // is where NP2kai keeps them too (dipsw[1] IS its port 0x31): compare the port.
          if (n == 1) read_raw(16'h0031, rtl_read);
          np = np_dipsw[n];
          // THIS EXPECTATION WAS INVERTED BY THE MACHINE'S EVIDENCE. NP2kai's STORE
          // masks each register's PARITY bit (bit 0 of 0x84, bit 4 of 0x85, bit 7 of
          // 0x86 - io/dipsw.c's `value & 0xfc / 0xef / 0x7f`) and this bench used to
          // expect ours to copy that mask byte for byte. It no longer does: the
          // firmware WRITES those bits (SETUP's parity idiom BANK3@0xFA219; the ITF's
          // `or al,0x80 / out 0x8E1E`) and the ITF's repair installs its factory tables
          // through these ports (BANK4@0xFC7E4, tables BANK4@0x480C/0x4818), so a frozen
          // parity bit composed the repair's 0x7F over the real machine 0xBF
          // (docs/probes/PORTS.TXT:258) into an EVEN 0xFF - the message LOOP. The
          // machine is a plain RAM at the one measured port (RDBACK.TXT:162 stores the
          // written 0x0C) and the Xa7C9W capture (qemu-pc98/roms/pc98bios/memsw.inc)
          // holds the factory byte 0x7F at exactly the cell the frozen bit trapped.
          // NP2kai disagrees on the write and is OVERRULED by the machine - the same
          // adjudication audit-iobus F4 made for the read side below. So the comparison
          // now asserts the DATA bits (each register's parity bit masked off); the
          // parity-bit write itself is the recorded divergence, and its falsifier is
          // `probe2 /RDBACK` at 0x8B1E/0x881E on the machine (if the machine masks the
          // bit there, the RTL change reverses).
          if ((rtl_read & (n == 0 ? 8'hFE : (n == 1 ? 8'hEF : 8'h7F))) !==
              (np     & (n == 0 ? 8'hFE : (n == 1 ? 8'hEF : 8'h7F)))) begin
            $display("FAIL NP2kai differential 0x%02x1E write=%02x rtl=%02x np2kai_stored=%02x (data bits)",
                     8'h84 + n, v == 0 ? 8'h54 : (v == 1 ? 8'h7F : 8'h01), rtl_read, np);
            errors = errors + 1;
          end
        end
      end
      $display("PRAM NP2kai differential: 0x84/0x85/0x86 DATA bits agree with io/dipsw.c's STORE on writes 54/7F/01 (the parity-bit write is the recorded divergence)");
      waive("NP2kai io/dipsw.c masks each register's PARITY bit on write; the firmware writes those bits and the machine stores them (the ITF's repair requires it)");

      // The other behaviour the capture refutes: NP2kai's READ forces the
      // odd-parity bit onto the stored byte, so after a write whose stored byte
      // is even it returns a different value. The machine returns the stored byte
      // verbatim (docs/probes/RDBACK.TXT:162, `wrote=0C after=0C`), so this is a
      // recorded divergence and not a failure. Shown for the three ports at the
      // state the loop above leaves each of them in.
      waive("NP2kai io/dipsw.c recomputes an odd-parity bit on every read; the machine returns the stored byte verbatim (docs/probes/RDBACK.TXT:162)");
      for (integer n = 0; n < 3; n = n + 1)
        $display("PRAM NP2kai read 0x%02x1E stored=%02x np2kai=%02x", 8'h84 + n, np_dipsw[n],
                 np_read(16'h841E + (n << 8)));

      // 0x871E and 0x8E1E: NP2kai reads them as PC-9801 control ports (DSW2 bit
      // 4 / DSW3 bit 7 plus the beep volume), not as stored bytes. The machine's
      // read-only capture reads 0x871E=0x3E and 0x8E1E=0x49, which only a stored
      // byte explains, so the RTL follows the machine.
      read_raw(16'h871E, rtl_read);
      np = np_read(16'h871E);
      waive("NP2kai io/dipsw.c reads 0x871E as a DSW2/beep control; the machine reads a stored byte");
      $display("PRAM 0x871E rtl=%02x np2kai=%02x machine=3E", rtl_read, np);
      read_raw(16'h8E1E, rtl_read);
      np = np_read(16'h8E1E);
      waive("NP2kai io/dipsw.c reads 0x8E1E as a DSW3 bit-7 control; the machine reads a stored byte");
      $display("PRAM 0x8E1E rtl=%02x np2kai=%02x machine=49", rtl_read, np);

      // NP2kai refuses a write whose value is not already odd parity
      // (`if (!(iflags[value] & 0x04))`). The machine accepts one: docs/probes/
      // RDBACK.TXT:162 writes the EVEN-parity 0x0C to 0x871E and reads it back
      // (`after=0C`), which is what the RTL does too - the writable bits are
      // stored whatever their parity, and nothing is recomputed on the read.
      // Recorded because NP2kai is the software reference and the capture is the
      // stronger one here.
      np_reset;   // both models start from the machine image again
      reset = 1;    // the machine-reset seed: the store's only restore now
      repeat (2) @(posedge clk);
      reset = 0;
      while (dut.sdip_seq_active) @(posedge clk);
      @(negedge clk);
      write_byte(16'h8F1F, 8'h80);
      write_byte(16'h841E, 8'h00);          // even parity: NP2kai rejects
      np_write(16'h841E, 8'h00);
      read_raw(16'h841E, rtl_read);
      np = np_read(16'h841E);
      waive("NP2kai io/dipsw.c rejects an even-parity write; the RTL stores its data bits, as the machine does at 0x871E (RDBACK.TXT:162)");
      $display("PRAM even-parity write 0x84,rtl=%02x np2kai=%02x (machine: RDBACK 0x871E stored an even 0x0C)", rtl_read, np);
    end

    // ---- 6. TWO BOOTS: the machine-reset strobe re-seeds the store, so what boot N writes is
    //         never what boot N+1's own verifier reads --------------------------------
    // THIS SECTION WAS INVERTED BY A DESIGN DECISION. The store is battery-backed on the
    // machine, but this core's power-up image is an `initial` (one copy in the RTL) and there was
    // NO reset path at all, so a platform reset used to leave whatever the previous boot had
    // written. The reported symptom - "resetting the machine causes a software dip switch reset
    // message to show back up", and, decisive: "if I manually reset the dip switches in the menu
    // it fixes the message for that particular boot, until the reset again" - says the failing
    // state is (a) store CONTENT and (b) PRODUCED BY A BOOT, not merely inherited. So this section
    // now replays a boot's own writes and then asserts the two-boot property: with the strobe on
    // the reset, the next boot starts from the cold-boot image, so the failing condition cannot
    // arise no matter what the previous boot left. The cost, stated rather than hidden: a guest
    // SETUP change does not survive a platform reset any more, where the machine's own store would
    // keep it - the deliberate divergence item 94 records.
    //
    // The store's own rewrite, from the dump: the ITF's 20-byte write-back pass is a SAME-VALUE
    // read-modify-write for 19 of the 24 bytes, and the ONE exception is bank A index 1, which the
    // ITF DERIVES (`BANK4@0xFC6CC-0xFC6DA`):
    //     in al,0x851E (what the store PRESENTS) ; ah = al
    //     in al,0x31   (the DIP-2 strap)         ; ax &= 0x10EF
    //     merged = (port31 & 0xEF) | (presented & 0x10) ; out 0x851E ; jnp (ODD parity)
    // Replaying it here is what makes this a two-boot test rather than a corruption test.
    begin
      integer n;
      reg [7:0] p31, presented, merged, next_read;
      integer visited_bad;

      reset = 1;    // the machine-reset seed: the store's only restore now
      repeat (2) @(posedge clk);
      reset = 0;
      while (dut.sdip_seq_active) @(posedge clk);
      @(negedge clk);
      write_byte(16'h8F1F, 8'h80);          // the bank-A select the ITF's pass uses
      // A guest SETUP change (index 2 = 0x15, odd data parity) plus the ITF's own derived write.
      write_byte(16'h861E, 8'h15);
      read_byte(16'h861E, 8'h15);
      read_raw(16'h0031, p31);
      read_raw(16'h851E, presented);
      merged = (p31 & 8'hEF) | (presented & 8'h10);
      write_byte(16'h851E, merged);
      @(negedge clk);
      read_raw(16'h851E, next_read);
      // (i) the predicate boot N+1's verifier applies to this byte - `test al,0ffh / jnp`, i.e.
      // ODD parity - and the value it applies it to. Both are displayed because the DIP bank is
      // the brief's prime suspect and this is the measurement that rules it in or out.
      if (!is_odd_parity(next_read))
        fail("bank A index 1 does not present an odd-parity byte to the next boot's verifier");
      // (ii) the same predicate over every byte the pass VISITS (the 20 of the 24: bank A
      // 0x84-0x88 and 0x8B-0x8F, bank B 0x84-0x8D - the 0x89/0x8A XOR pair and bank B's 0x8E/0x8F
      // are read/handled differently and are not in this arm). Our store presents those verbatim.
      visited_bad = 0;
      write_byte(16'h8F1F, 8'h80);
      for (n = 0; n < 12; n = n + 1) begin
        if ((n < 5) || (n > 6)) begin
          read_raw(16'h841E + (n << 8), got);
          if (!is_odd_parity(got)) visited_bad = visited_bad + 1;
        end
      end
      write_byte(16'h8F1F, 8'hC0);          // bank B: 0x84..0x8D
      for (n = 0; n < 10; n = n + 1) begin
        read_raw(16'h841E + (n << 8), got);
        if (!is_odd_parity(got)) visited_bad = visited_bad + 1;
      end
      write_byte(16'h8F1F, 8'h80);
      $display("  two boot: p31=%02x presented=%02x store[1]=%02x next_read=%02x; 20-byte pass: %0d byte(s) fail odd parity",
               p31, presented, dut.sdip[1], next_read, visited_bad);
      if (visited_bad != 0)
        fail("a byte the ITF's own pass visits is not odd parity out of this boot");
      if (dut.sdip[2] === machine_banka[2])
        fail("the machine-reset seed check is vacuous: the guest write never moved the store");

      // ---- the reset: the next boot starts from the cold-boot image ---------------------
      reset = 1;
      repeat (2) @(posedge clk);
      @(negedge clk);
      reset = 0;
      write_byte(16'h8F1F, 8'h80);          // the gate resets shut; reopen
      for (n = 0; n < 12; n = n + 1)
        if (dut.sdip[n] !== machine_banka[n])
          fail("the machine-reset strobe left a bank A byte off the power-up image");
      read_byte(16'h861E, machine_banka[2]);   // the guest's byte is GONE: the image is back
      read_byte(16'h851E, machine_banka[1]);   // ... including the one the ITF derived
      read_byte(16'h881E, machine_banka[4]);   // and an untouched cell
      read_raw(16'h851E, next_read);           // the same byte boot 2's ITF will present
      $display("  two boot after the reset: store[1]=%02x next_read=%02x (the image byte)",
               dut.sdip[1], next_read);
      if (dut.sdip[1] !== machine_banka[1])
        fail("the reset did not restore the byte the previous boot's ITF had derived");
    end

    // ---- 7. THE ITF'S REPAIR must be able to repair: BANK4@0xFC7B2-0xFC8DE replayed ----
    // The repair is what runs when ANY gate fails, its tail always prints SET THE SOFTWARE
    // DIP-SWITCH (gs = 0x48DE is loaded at BANK4@0xFC8D9 and dispatched), and its factory
    // install goes out through the 0x841E-0x8F1E PORTS - so it is subject to the store's
    // write composition. Replayed here byte for byte as the dump has it:
    //
    //   FC7D6: in 0x8B1E / and al,0x40 / mov ah,al      ; save bank-A 0x8B's bit 6
    //   FC7E4: out 0x8F1F,0x80; 12 x lodsb/out          ; BANK4@0x480C -> bank A
    //   FC7F0: out 0x8F1F,0xC0; 12 x lodsb/out          ; BANK4@0x4818 -> bank B
    //   FC856: in 0x8B1E / or al,ah / out dx,al         ; bit 6 ORed back (an OR, not a merge)
    //
    // and then THE ITF'S OWN acceptance predicate over what the next check reads
    // (BANK4@0xFC6BA-0xFC726: whole-byte odd parity on the 20 examined bytes plus the
    // 0x89^0x8A XOR pair, and the 0x851E merge of BANK4@0xFC6CC-0xFC6DA). Expected values
    // are the firmware's own factory tables, copied from the dump at BANK4@0x480C/0x4818 -
    // never from our RTL. A repair that cannot make the next check pass is the message LOOP:
    // repair -> message -> out 0xF0 -> re-POST -> repair -> ... until a machine reset.
    begin
      integer n, bad;
      reg [7:0] fact_a [0:11];
      reg [7:0] fact_b [0:11];
      reg [7:0] bit6, rd, p31, presented, merged;
      // BANK4@0x480C (bank A) and BANK4@0x4818 (bank B), verbatim from the dump.
      fact_a[0]=8'h7C;  fact_a[1]=8'h73;  fact_a[2]=8'h76;  fact_a[3]=8'h3E;
      fact_a[4]=8'hDC;  fact_a[5]=8'h7F;  fact_a[6]=8'hFF;  fact_a[7]=8'h7F;
      fact_a[8]=8'h7F;  fact_a[9]=8'h7F;  fact_a[10]=8'h49; fact_a[11]=8'h98;
      fact_b[0]=8'h8F;
      for (n = 1; n < 12; n = n + 1) fact_b[n] = 8'h80;

      // The machine image first (the reset seed), so the repair starts from the state the
      // measured Xe10 reports: bank A idx 7 = 0xBF (docs/probes/PORTS.TXT:258), whose bit 7
      // differs from the factory byte's - the case the write composition must survive.
      reset = 1;
      repeat (2) @(posedge clk);
      @(negedge clk);
      reset = 0;
      write_byte(16'h8F1F, 8'h80);
      if (dut.sdip[7] !== 8'hBF)
        fail("the repair-replay premise is vacuous: idx 7 is not the machine image 0xBF");

      // THE REPAIR, in the firmware's own order.
      read_raw(16'h8B1E, rd);
      bit6 = rd & 8'h40;                       // FC7D6
      for (n = 0; n < 12; n = n + 1)           // FC7E4: the factory table over bank A
        write_byte(16'h841E + (n << 8), fact_a[n]);
      write_byte(16'h8F1F, 8'hC0);
      for (n = 0; n < 12; n = n + 1)           // FC7F0: the factory table over bank B
        write_byte(16'h841E + (n << 8), fact_b[n]);
      write_byte(16'h8F1F, 8'h80);
      read_raw(16'h8B1E, rd);
      write_byte(16'h8B1E, rd | bit6);         // FC856

      // THE PREDICATE. Every byte the ITF's odd-parity pass examines must be odd, the XOR
      // pair must be odd, and the 0x851E merge must be odd.
      bad = 0;
      for (n = 0; n < 12; n = n + 1) begin
        // The direct pass covers 0x84 and 0x86-0x88 and 0x8B-0x8F; 0x851E is the MERGE
        // byte (checked below) and 0x89/0x8A are the XOR pair.
        if ((n != 1) && (n != 5) && (n != 6)) begin
          read_raw(16'h841E + (n << 8), rd);
          if (!is_odd_parity(rd)) begin
            $display("FAIL repair replay: bank A 0x%02x1E = %02x is not odd parity after the factory install",
                     8'h84 + n, rd);
            bad = bad + 1;
          end
        end
      end
      read_raw(16'h891E, rd);
      presented = rd;
      read_raw(16'h8A1E, rd);
      if (!is_odd_parity(presented ^ rd)) begin
        $display("FAIL repair replay: the 0x89/0x8A XOR %02x is not odd parity", presented ^ rd);
        bad = bad + 1;
      end
      write_byte(16'h8F1F, 8'hC0);
      for (n = 0; n < 10; n = n + 1) begin
        read_raw(16'h841E + (n << 8), rd);
        if (!is_odd_parity(rd)) begin
          $display("FAIL repair replay: bank B 0x%02x1E = %02x is not odd parity after the factory install",
                   8'h84 + n, rd);
          bad = bad + 1;
        end
      end
      write_byte(16'h8F1F, 8'h80);
      read_raw(16'h0031, p31);
      read_raw(16'h851E, presented);
      merged = (p31 & 8'hEF) | (presented & 8'h10);
      if (!is_odd_parity(merged)) begin
        $display("FAIL repair replay: the 0x851E merge %02x is not odd parity", merged);
        bad = bad + 1;
      end
      // The factory byte itself, read where the repair installed it: BANK4@0x480C[7] = 0x7F.
      read_raw(16'h8B1E, rd);
      if (rd !== fact_a[7]) begin
        $display("FAIL repair replay: bank A 0x8B1E = %02x after the factory install, want %02x (BANK4@0x480C[7])",
                 rd, fact_a[7]);
        bad = bad + 1;
      end
      $display("  repair replay: %0d byte(s) fail the ITF's own predicate after the factory install (0x8B1E=%02x)",
               bad, rd);
      if (bad != 0)
        fail("the ITF's repair cannot restore an acceptable DIP image - the message loop would form");

      // The repair must be a FIXED POINT: a second run over the state it just left changes
      // nothing the predicate sees (otherwise the re-POST after the message re-enters it).
      read_raw(16'h8B1E, rd);
      bit6 = rd & 8'h40;
      for (n = 0; n < 12; n = n + 1)
        write_byte(16'h841E + (n << 8), fact_a[n]);
      write_byte(16'h8F1F, 8'hC0);
      for (n = 0; n < 12; n = n + 1)
        write_byte(16'h841E + (n << 8), fact_b[n]);
      write_byte(16'h8F1F, 8'h80);
      read_raw(16'h8B1E, rd);
      write_byte(16'h8B1E, rd | bit6);
      read_raw(16'h8B1E, rd);
      if (rd !== fact_a[7]) begin
        $display("FAIL repair replay: a second repair moved 0x8B1E to %02x (the install is not a fixed point)", rd);
        bad = bad + 1;
      end
      if (bad != 0) fail("the ITF's repair is not a fixed point of the store");
      $display("  repair replay: second install is a fixed point (0x8B1E=%02x)", rd);
    end

    // ==== VERDICT ====
    if (errors != 0) begin
      $display("TB_PC9821_PRAM: FAIL (%0d errors, %0d waived)", errors, waived);
      $fatal(1, "pram bench failed");
    end else begin
      $display("TB_PC9821_PRAM: PASS");
      $display("  %0d ITF-verifier bytes, %0d waivers", wchecks, waived);
      $finish;
    end
  end

  // A bound that does not depend on the stimulus: the bench must terminate even
  // if a task spins, or the runner's wall clock is the only limit.
  initial begin
    repeat (200_000) @(posedge clk);
    $fatal(1, "TB_PC9821_PRAM: watchdog timeout");
  end
endmodule
