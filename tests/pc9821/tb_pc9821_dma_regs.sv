`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The uPD71071's eight address/count ports are four 16-bit PAIRS behind ONE shared byte flip-flop, not eight independent byte latches - a single write then two reads returns the written byte then the untouched high half, two different writes then two reads return both bytes in order, a write to a neighbouring channel does not leak into 0x01, and the flip-flop is genuinely shared so a write to 0x01 moves which half a later write to 0x03 lands in - while the ITF's own doubled self-test (BANK4@0x3E9) still passes, which eight latches satisfied by accident. Plus 0x19, the 8237's clear-byte-pointer: writing it resets the shared flip-flop to LOW (NP2kai dmac_o19, io/dmac.c:196-200) so the next byte write lands the low half (FAIL-FIRST against an undecoded 0x19, which lands it in the wrong half silently); 0x19 is not one of the eight register ports, so it does not itself toggle the flip-flop and its read is the write-only port's 0xFF.
//
// The uPD71071's eight address/count ports are four 16-bit PAIRS behind ONE shared byte flip-flop, not eight independent byte latches - a single write then two reads returns the written byte then the untouched high half, two different writes then two reads return both bytes in order, a write to a neighbouring channel does not leak into 0x01, and the flip-flop is genuinely shared so a write to 0x01 moves which half a later write to 0x03 lands in - while the ITF's own doubled self-test (BANK4@0x3E9) still passes, which eight latches satisfied by accident. Plus 0x19, the 8237's clear-byte-pointer: writing it resets the shared flip-flop to LOW whatever parity it was left at (NP2kai dmac_o19 sets `dmac.lh = DMA16_LOW`, io/dmac.c:196-200), so the next address/count byte lands the low half - where an undecoded 0x19 silently lands it in the wrong half.
//
// ---- the bench's own account of where each expectation comes from ----
//
// This is the specification for the DMA address and count registers, and NO
// BENCH IN THIS TREE HAD IT before this one. A uPD71071 is 8237-compatible, and
// every address and count register is a 16-bit value reached through an 8-bit
// port, so the chip carries a byte flip-flop: the access lands in the low half
// while it is clear and the high half while it is set, and it toggles on every
// such access. There is ONE flip-flop for the whole controller, not one per
// register, which is what makes a write to one port change where the next write
// to a DIFFERENT port lands.
//
//  1. THE EIGHT PORTS ARE FOUR PAIRS. NP2kai's port tables are explicit
//     (io/dmac.c:324-334): table entries 0..7 -- ports 0x01,0x03,...,0x0F --
//     are o01,o03,o01,o03,o01,o03,o01,o03, and both handlers select the channel
//     as `(port >> 2) & 3` with o01 writing the ADDRESS and o03 the COUNT
//     (io/dmac.c:128-157). So 0x01/0x03 are channel 0's address and count,
//     0x05/0x07 channel 1's, 0x09/0x0B channel 2's, 0x0D/0x0F channel 3's --
//     the 8237 layout. In this core that is channel = port[3:2] and
//     address-vs-count = port[1].
//     [source: NP2kai io/dmac.c, the reference model for a chip this project has
//      never probed register-by-register]
//
//  2. ONE SHARED FLIP-FLOP, TOGGLED BY EVERY ACCESS IN EVERY CHANNEL, READ OR
//     WRITE. `lh = dmac.lh; dmac.lh = lh ^ 1;` in dmac_o01, dmac_o03, dmac_i01
//     and dmac_i03 alike, indexing `adrs.b[lh + DMA32_LOW]` and `leng.b[lh]`
//     (io/dmac.c:128-157, 268-288). It resets clear (dmac_reset sets
//     `dmac.lh = DMA16_LOW`, io/dmac.c:340-347), so the first access after reset
//     is a low-half access.
//     [source: NP2kai io/dmac.c]
//
//  3. THE ITF'S OWN SELF-TEST IS WRITTEN FOR THIS AND CANNOT SEE IT. At
//     BANK4@0x3E9 the firmware writes each of the eight ports TWICE and then
//     reads it TWICE, comparing both reads to the value it wrote:
//         out dx,al / out dx,al / in al,dx / mov ah,al / in al,dx / cmp bx,ax
//     That is four accesses per register -- an even number, so the shared
//     flip-flop is back to low at every register boundary -- and because both
//     writes carry the SAME value, both halves hold it, so both reads return it.
//     Eight independent byte latches pass that test identically. That is why the
//     defect below survived the firmware's own check, and why the bench that
//     mirrored the firmware's shape (tb_pc9821_iobus.sv, one write then one read)
//     could not catch it either: A SEQUENCE THAT WRITES THE SAME BYTE TWICE AND
//     READS TWICE CANNOT DISTINGUISH A PAIR FROM TWO LATCHES.
//     [source: bios/xe10/BANK4.BIN@0x3E9, disassembled]
//
//  4. THE COMPATIBILITY REQUIREMENT. Whatever else changes, the sequence the
//     firmware actually performs must keep working, so this bench replays it
//     verbatim (two writes then two reads per port, both reads equal to the
//     written byte, for 0xFF and then for 0x00). A model that got the pair
//     semantics right but broke this would fail the POST; a model that gets
//     both right satisfies the chip and the firmware.
//     [source: bios/xe10/BANK4.BIN@0x3E9; the second pass with 0x00 is the
//      open-bus check the same routine performs]

module tb_pc9821_dma_regs;
  // System port C bit 3: the beeper's MUTE (pc9821_iobus, ANDed with the PIT's
  // channel 2 in pc9821_system). This bench does not drive the beeper, but it
  reg [3:0]  bios_set = 4'd0;      // OSD BIOS set: 0 = PC-9821Xe10 (the default strap)
  // The OSD GDC Clock field (port 0x31 bit 7: 0 = the measured 2.5 MHz strap, 1 = 5 MHz).
  // Static here: this bench is not about the strap and an UNDRIVEN input is 0, which is
  // the machine's own state - tb_pc9821_bios_select and tb_pc9821_userdisk own the field.
  reg  gdc_clock_5m = 1'b0;
  reg  msw_hold = 1'b0;        // port 0x31 bit 4 at the measured machine's memory-switch init (0xF3)
  reg  text_lines_20 = 1'b0;   // port 0x31 bit 3 at the measured 25 lines (0xF3)
  reg  [1:0] floppy_mode = 2'd0;   // Auto (1M), 0x861E = 0xF7: the Floppy mode default
  wire [23:0] setup_cfg;       // the OSD configuration pc9821_cg is built from (unread here)
  // instantiates pc9821_iobus with (.*), which needs every port named -
  // tools/check_wiring.py enforces that, and it caught exactly this when the
  // port was added. tb_pc9821_beeper covers the behaviour.
  wire        beep_mute;
  wire [1:0]  beep_vol;   // 0x871E bits [3:2], the beeper volume (see pc9821_iobus)
  reg clk = 0;
  always #5 clk = ~clk;      // 10 ns, clk_sys

  reg reset = 1;
  reg triple_fault_reset = 0;
  reg [31:0] cpu_addr = 0, cpu_din = 0;
  reg [3:0]  cpu_be = 0;
  reg        cpu_valid = 0, cpu_write = 0;
  wire [31:0] cpu_dout;
  wire        cpu_ready, cpu_resp_valid;
  reg [7:0]  debug_status = 8'hA5;
  reg        cal_cdat = 0;
  // The configuration-image seed (pc9821_gdc_text's cfg_* block / pc9821_iobus's memory-switch
  // strap cell): 0 = no seed, which is what this bench wants. tb_pc9821_cg_read_path drives it.
  wire [6:0] cfg_ram_mib = 7'd0;
  wire       cfg_seed_en = 1'b0;
  reg [7:0]  device_io_dout = 8'hC3;
  reg        device_rd_wait = 1'b0;
  reg        egc_gate = 1'b0;
  // The remaining ports are declared because `.*` needs a net for every port;
  // this bench drives and observes only the CPU-side byte handshake.
  wire       sdip_seed_pulse;   // the machine-reset seed's one-shot (pc9821_iobus)
  wire        device_io_wr, device_io_rd;
  wire [15:0] device_io_addr;
  wire  [7:0] device_io_din;
  wire  [3:0] top_bank;
  wire        sound_extend;
  wire  [7:0] win0_sel;
  wire       win0_sel_moved;   // pc9821_iobus's registered `win0_sel != 8'h08`
  wire sys16m_en;   // 0x043B bit 2, the 15-16 MiB system-space window
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
  wire [15:0] dbg_last_io_addr;   // the most recent I/O access (the IO/DR/IV fields)
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
  // The core's native whole-L1 flush handshake (iobus's cache_flush_req /
  // cache_flush_busy / cache_flush_done), modelled here at ZERO LATENCY: this
  // bench does not measure flush timing, and an unmodelled cache_flush_done
  // would leave any flush-triggering write waiting in iobus's S_FLUSH forever.
  // The real request/done contract is tb_pc9821_cache_flush's subject.
  wire cache_flush_req;
  wire crt31k;   // 0x09A8 bit 0 (pc9821_iobus), named so .* binds it
  wire cache_flush_busy = 1'b0;
  wire cache_flush_done = cache_flush_req;

  // ==== DUT ====
  // 0x043F EMS page register / window select (pc9821_iobus outputs).
  wire [1:0] ems_state;
  wire top_shadow_en;
  wire soft_reboot;   // pc9821_iobus's reboot strobe (0x534)
  // The FDC's level interrupt (slave PIC IRQ11). pc9821_iobus carries the
  // port and the `.*` DUT instantiation matches by name, so it must
  // be declared here; this bench does not exercise the floppy path.
  wire        fdc_irq;
  wire        fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window

  reg device_rd_hold = 1'b0;
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

  // ONE read, checked against the half the flip-flop should be selecting.
  // The whole bench is written as a single linear sequence of accesses, so the
  // flip-flop's parity at every point is countable from the list below -- which
  // is the only way to state an expectation for a chip whose register is half a
  // 16-bit value per access. Each comment names the parity it expects.
  task automatic rd_is(input [15:0] portnum, input [7:0] want, input [8*100-1:0] what);
    reg [7:0] got;
    begin
      rd1(portnum, got);
      if (got !== want) begin
        $display("FAIL %0s: port %04x read %02x, expected %02x", what, portnum, got, want);
        errors = errors + 1;
      end
    end
  endtask

  // ==== CHECKS ====
  // The flip-flop starts CLEAR (dmac_reset sets dmac.lh = DMA16_LOW), so the
  // first access below is a LOW-half access and the parity alternates from there.
  initial begin
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);

    // ---- after reset both halves of channel 0's address are zero ----
    rd_is(16'h0001, 8'h00, "1 reset: ch0 address low half");      // FF 0 -> 1
    rd_is(16'h0001, 8'h00, "2 reset: ch0 address high half");     // FF 1 -> 0

    // ---- ONE WRITE, THEN THE HALVES IN ORDER -------------------------
    // The write takes the LOW half (FF is clear) and leaves FF set, so the very
    // next access is a HIGH-half access. That is the whole difference from a
    // byte latch: a latch returns the written byte on BOTH reads.
    wr(16'h0001, 8'hAA);                                           // FF 0 -> 1, low = AA
    rd_is(16'h0001, 8'h00, "3 the write took the LOW half, so high still reads 0"); // FF 1 -> 0
    rd_is(16'h0001, 8'hAA, "4 ...and the low half reads the byte written");         // FF 0 -> 1

    // ---- TWO DIFFERENT WRITES, TWO READS: both halves, in order -------
    // (latch: 22,22)
    wr(16'h0001, 8'h11);                                           // FF 1 -> 0, high = 11
    wr(16'h0001, 8'h22);                                           // FF 0 -> 1, low  = 22
    rd_is(16'h0001, 8'h11, "5 two writes: high half holds the first byte");  // FF 1 -> 0
    rd_is(16'h0001, 8'h22, "6 ...and low holds the second");                 // FF 0 -> 1

    // ---- A WRITE AND A READ TAKE OPPOSITE HALVES ----------------------
    // (latch: 33,33)
    wr(16'h0001, 8'h33);                                           // FF 1 -> 0, HIGH = 33
    rd_is(16'h0001, 8'h22, "7 after a write the next read is the OTHER half");  // FF 0 -> 1
    rd_is(16'h0001, 8'h33, "8 ...and the one after that is the written half");  // FF 1 -> 0

    // ---- THE PAIRING: A NEIGHBOURING CHANNEL IS NOT THIS CHANNEL ------
    // 0x05 is channel 1's address. Write it, then channel 0's address must read
    // back exactly what it held before. A model keyed on the PORT alone returns
    // the channel-1 byte here.
    wr(16'h0005, 8'h5A);                                           // ch1 addr, FF 0 -> 1 (its low half)
    rd_is(16'h0001, 8'h33, "9 ch1's write left ch0's address high half alone");  // FF 1 -> 0
    rd_is(16'h0001, 8'h22, "10 ...and its low half alone");                     // FF 0 -> 1

    // ---- THE FLIP-FLOP IS SHARED, and this is the only check that says so --
    // Write 0x01 (low half of ch0 address), then 0x03. 0x03 is ch0's COUNT, and
    // because 0x01's write left the flip-flop SET, the count's byte lands in its
    // HIGH half. So the count reads (0x00, 0x88): low never written.
    //   a per-PORT latch         -> (0x88, 0x88)
    //   a per-REGISTER flip-flop -> (0x88, 0x00)
    //   one shared flip-flop     -> (0x00, 0x88)   <- the chip
    wr(16'h0001, 8'h77);                                           // FF 0 -> 1, ch0 addr low = 77
    wr(16'h0003, 8'h88);                                           // FF 1 -> 0, ch0 COUNT HIGH = 88
    rd_is(16'h0003, 8'h00, "11 the shared flip-flop sent 0x03's write to the HIGH half"); // FF 0 -> 1
    rd_is(16'h0003, 8'h88, "12 ...and the count's high half holds it");                   // FF 1 -> 0

    // ---- COMPATIBILITY: the firmware's own sequence, replayed verbatim ----
    // BANK4@0x3E9: for each of the eight ports, write the value twice, read it
    // twice, and require BOTH reads to equal it; then repeat with 0x00 as the
    // open-bus check. Four accesses per register is even, so the shared flip-flop
    // self-aligns at every port boundary whatever parity it entered with -- which
    // is exactly why the firmware's test cannot see the defect this bench is for.
    begin : firmware_sequence
      reg [7:0] v;
      integer k;
      reg [15:0] p;
      reg [7:0] g1, g2;
      v = 8'hFF;
      for (k = 0; k < 2; k = k + 1) begin
        for (p = 16'h0001; p <= 16'h000F; p = p + 16'h0002) begin
          wr(p, v);
          wr(p, v);
          rd1(p, g1);
          rd1(p, g2);
          if (g1 !== v || g2 !== v) begin
            $display("FAIL the ITF's own self-test shape no longer passes: port %04x wrote %02x twice, read (%02x,%02x)",
                     p, v, g1, g2);
            errors = errors + 1;
          end
        end
        v = 8'h00;
      end
    end

    // ---- MASTER CLEAR zeroes every channel's address and count ---------
    // Both references agree: NP2kai's dmac_o1b zeroes all four channels' adrs.d
    // and leng.w (io/dmac.c:202-215) and the 8237's master clear does the same.
    // A write to 0x1B is NOT one of the eight register ports, so it does not move
    // the flip-flop; the two writes below fill BOTH halves of channel 0's address
    // and the two reads after the clear cover both halves exactly once, whatever
    // parity the previous check left behind. That is what makes this check
    // independent of everything above it: if master clear is dropped, the two
    // reads return 0x11 and 0x22 in some order and at least one of them is wrong.
    wr(16'h0001, 8'h11);
    wr(16'h0001, 8'h22);
    wr(16'h001B, 8'h00);
    rd_is(16'h0001, 8'h00, "13 master clear zeroed channel 0's address, one half");
    rd_is(16'h0001, 8'h00, "14 ...and the other half");

    // ---- 0x19 IS CLEAR BYTE POINTER: it resets the shared flip-flop ---------
    // NP2kai's dmac_o19 is `dmac.lh = DMA16_LOW` (io/dmac.c:196-200): one write
    // to 0x19 and the NEXT address/count access takes the low half whatever
    // parity the flip-flop was left at. The flip-flop's parity is P-relative to
    // the cases above (every access toggles it, so no port-visible sequence can
    // pin its absolute state), so it is seeded hierarchically to SET - setup,
    // not an expectation; the expected bytes are still NP2kai's. Seeded set, a
    // write to 0x01 takes the HIGH half; after `out 0x19` the next write must
    // take the LOW half, so the read pair after it is (high half, written byte).
    // FAIL-FIRST: with 0x19 undecoded the flip-flop stays set, 44 lands the HIGH
    // half (over the 11) and the first read of the pair returns 22 (the
    // untouched low half) instead of 11. A 0x19 access is NOT one of the eight
    // register accesses, so it does not itself toggle the flip-flop, and its own
    // read is the write-only port's 0xFF (machine B1-B7).
    repeat (2) @(negedge clk);
    dut.u_dma.lh = 1'b1;                                         // FF seeded SET
    wr(16'h0001, 8'h11);                                           // FF 1 -> 0, high = 11
    wr(16'h0001, 8'h22);                                           // FF 0 -> 1, low  = 22
    wr(16'h0019, 8'h00);                                           // clear byte pointer: FF -> 0
    rd_is(16'h0019, 8'hFF, "15 0x19 is write-only, reads FF");     // no toggle
    wr(16'h0001, 8'h44);                                           // FF 0 -> 1, low  = 44
    rd_is(16'h0001, 8'h11, "16 the write after 0x19 landed LOW");  // FF 1 -> 0, high still 11
    rd_is(16'h0001, 8'h44, "17 ...and the low half holds 44");     // FF 0 -> 1

    // ---- THE BANK (0x21..0x27) AND BOUND (0x29) BLOCK -----------------
    // THESE STATE CHECKS NOW READ pc9821_dmac's OWN REGISTERS, because that is where the
    // register file moved: pc9821_iobus instantiates the engine (u_dma) and 0x01..0x29 are
    // its `idx = port[5:1]` window, so the stub this bench was written against no longer
    // exists. The stub's `dma_bank[c]` is the engine's channel-address bank byte
    // (ch_addr[c][23:16]) and its `dma_bound[c]` is ch_bound[c]; the guest-visible BYTES
    // are asserted through the ports exactly as before, so the hand-off is checked on both
    // sides of the boundary.
    // A DIFFERENT register block from the pairs above (it is not behind the
    // flip-flop: 0x2x has port_addr[15:4] != 0, so it does not toggle it), and
    // the alignment the bank-register hand-off needs. The machine cannot pin either
    // register's internal layout - RDBACK writes the SAME byte to all four bank
    // ports (docs/probes/RDBACK.TXT:153-156) and all three bound writes carry
    // `dat & 3 == 0` - so the map comes from the two software references and this
    // core's engine, which agree three ways: NP2kai's `((port >> 1) + 1) & 3`
    // (io/dmac.c:236-237), qemu's same formula stated as a contract in its header
    // ("page registers at 0x21/0x23/0x25/0x27 (mapping ch1,2,3,0)",
    // hw/dma/pc98-dma.c:6,269-272), and pc9821_dmac.sv:204 `cpu_bank_ch = idx[1:0] + 2'd1`. Each port
    // reads its own channel, so no port-visible sequence can tell the rotations apart: the
    // check below is on the STATE, which is exactly what the hand-off moves.
    // FAIL-FIRST: before the alignment 0x21 stored into channel 0.
    wr(16'h0021, 8'hA5);
    if (dut.u_dma.ch_addr[1][23:16] !== 8'hA5) begin
      $display("FAIL 18 0x21 is channel 1's bank: ch_addr[1][23:16]=%02x, want A5",
               dut.u_dma.ch_addr[1][23:16]);
      errors = errors + 1;
    end
    if (dut.u_dma.ch_addr[0][23:16] !== 8'h00) begin
      $display("FAIL 18 0x21 must leave channel 0's bank alone: ch_addr[0][23:16]=%02x",
               dut.u_dma.ch_addr[0][23:16]);
      errors = errors + 1;
    end
    wr(16'h0027, 8'h3C);
    if (dut.u_dma.ch_addr[0][23:16] !== 8'h3C) begin
      $display("FAIL 18 0x27 is channel 0's bank: ch_addr[0][23:16]=%02x, want 3C",
               dut.u_dma.ch_addr[0][23:16]);
      errors = errors + 1;
    end
    // ...and the PORT reads still return the capture's nibble, at either port.
    rd_is(16'h0021, 8'h05, "19 0x21 reads back the capture's low nibble");
    rd_is(16'h0027, 8'h0C, "20 0x27 reads its own channel's low nibble");
    // 0x29 stores `(dat >> 2) & 3` into the channel `dat & 3` selects (NP2kai
    // `dmac.dmach + (dat & 3)`, io/dmac.c:260-263; qemu `regs[data & 3]`,
    // hw/dma/pc98-dma.c:269-272) and the READ exposes CHANNEL 0 ALONE
    // (pc9821_dmac.sv:545 `ch_bound[0]` - neither reference has a 0x29 read at all).
    // FAIL-FIRST: with one global latch the read followed the LAST write, so
    // the channel-1 row below read 03 and the channel-0 one read 00.
    wr(16'h0029, 8'h0D);
    if (dut.u_dma.ch_bound[1] !== 2'd3) begin
      $display("FAIL 21 0x29 write 0D is channel 1's bound 3: ch_bound[1]=%0d",
               dut.u_dma.ch_bound[1]);
      errors = errors + 1;
    end
    rd_is(16'h0029, 8'h00, "22 0x29 exposes channel 0 alone: a channel-1 write leaves 00");
    wr(16'h0029, 8'h0C);
    rd_is(16'h0029, 8'h03, "23 0x29 channel-0 write 0C reads 03 (probes/RDBACK.TXT:157)");
    rd_is(16'h0029, 8'h03, "24 ...and the read does not consume it");

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_DMA_REGS: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_DMA_REGS: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: a bench that blocks on a DUT signal with no bound hangs CI.
  initial begin
    #4_000_000;
    $fatal(1, "TB_PC9821_DMA_REGS: TIMEOUT");
  end

endmodule
