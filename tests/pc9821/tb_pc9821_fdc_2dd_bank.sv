`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// One uPD765 sits behind TWO port windows: the 0x00BE strap (bit 0) selects whether 0x90/0x92/0x94 or 0xC8/0xCA/0xCC answers, and the same bit routes the controller's completion to IRQ11 (slave_irq[3]) or IRQ10 (slave_irq[2]) and its DMA handshake to channel 2 or channel 3; the unselected window answers the open bus 0xFF and drops writes (NP2kai's gate), the register index is the same in both banks, the 2DD window's control port answers NP2kai's 0x74 where the 2HD one answers the machine's 0x44, and a floppy READ issued on the 2DD window moves the sector over DMA channel 3 while the same command on the 2HD window still uses channel 2. The FDD-mode switch reads back as 0x00BE/0x00BF bit 2 - Fixed FF, Auto FB (FA after writing 0x02) - and the read follows the switch only across a reset (POST samples it).
//
// THE 2DD BANK, DRIVEN AT THE PORT LEVEL because the port decode IS the feature: the same
// pc9821_iobus the machine boots through is poked at 0x90/0x92/0x94, 0xC8/0xCA/0xCC,
// 0x00BE and the uPD71071's register window, with a media model on the fdd_* seam and a
// memory model on the dma_mem_* port. A module-level bench cannot express "the same
// controller at two addresses" at all.
//
// THE ARCHITECTURE THIS PINS (the reference behind each case is named in its own
// comment):
//   * the 2DD bank is a SECOND PORT WINDOW onto the one register file, not a second
//     controller. NP2kai binds the same handler table at 0x0090 and 0x00C8 behind
//     `((port >> 4) ^ fdc.chgreg) & 1` (io/fdc.c:1162-1171, gate at :975/996/1040/1050/1068);
//     qemu-pc98 keeps one FDCtrl with `case 0x90` and `case 0xc8` in one switch
//     (hw/block/pc98-fdc.c:2789, 2808-2818); MAME maps one upd765a_device at both windows
//     (pc9821.cpp:725,732) under its own `// TODO: should really be one FDC` (pc9801.h:162);
//     and the machine's own firmware branches on 0x00BE bit 0 before every FDC access AND
//     programs DMA ch2 or ch3 from the same bit (the ITF's copies in BANK4, BANK7 0x741B).
//   * the strap selects THREE things together, which is what makes it one controller with
//     two doors rather than two devices: the window, the IRQ (NP2kai fdc_intwait, io/fdc.c
//     :43-56, pic_setirq(0x0b) vs (0x0a)) and the DMA channel (fdc_dmaready, :85-92,
//     FDC_DMACH2HD = 2 / FDC_DMACH2DD = 3 at :22-27).
//
// TWO OF THE ELEVEN CASES ARE CAPTURE-PENDING, and each is NAMED for the reference it
// follows so a capture flips a named assertion rather than silently changing a byte:
//   * hd_window_dead_under_2dd_strap follows NP2KAI (the unselected window answers 0xFF and
//     swallows writes). qemu-pc98 and MAME ALIAS instead, and MAME carries a TODO saying it
//     should be gated - so this is the one behavioural bit the references do not agree on,
//     and no capture in docs/probes/ reads these ports (PORTS.TXT skips 0x5B-0xEF).
//   * control_port_byte_2dd follows NP2KAI's fdc_i94 (`if (!(port & 0x10))` sets 0x20 and
//     0x10: io/fdc.c:1064-1078) - the 2DD door answers 0x74 and the 2HD door keeps the 0x44
//     this machine has been measured at (docs/probes/PORTS.TXT). QEMU-PC98 DISAGREES IN THE
//     OTHER DIRECTION (FDSTAT_DMA at 0x94 and not at 0xcc, hw/block/pc98-fdc.c:2816-2827);
//     MAME agrees with NP2kai (pc9801.cpp:571-580). The tree's evidence hierarchy puts
//     NP2kai first, so that is what is built - and the case names both readings.
//
// EACH CASE AND WHERE ITS EXPECTATION COMES FROM:
//   1  strap_readback              NP2kai fdc_ibe (`(chgreg & 3) | 0xf8`, io/fdc.c:1112-1114)
//   2  msr_2dd_window              NP2kai fdc_i90 returns fdc.status through either door
//   3  command_2dd_window          NP2kai fdc_datawrite reached from fdc_o92 at 0xC8 (:971-981)
//   4  irq_dest_2dd                NP2kai fdc_intwait, pic_setirq(0x0a) for chgreg & 1 == 0
//   5  irq_dest_2hd                the same, pic_setirq(0x0b) - the mux, not just the line
//   6  dma_ch3_2dd                 NP2kai fdc_dmaready picks FDC_DMACH2DD = 3
//   7  dma_ch2_2hd                 regression guard: FDC_DMACH2HD = 2 still selected at 0x03
//   8  dma_chann_qualifier         the other channel's strobe cannot move these bytes
//   9  hd_window_dead_under_2dd_strap   NP2kai's gate (capture-pending; qemu/MAME alias)
//  10  control_port_byte_2dd       NP2kai fdc_i94 (capture-pending; qemu disagrees)
//  11  boot_golden_precondition    chgreg resets to 3 (NP2kai fdc_reset, :1159), so the
//                                  ITF's own 0xC8 probes are gated out and the boot golden
//                                  (CYCLES used=930542) cannot move
// ==== DUT ====

module tb_pc9821_fdc_2dd_bank;
  reg clk = 0;
  always #5 clk = ~clk;   // 100 MHz, the same clk_sys the fit uses
  reg reset = 1;

  // ==== the CPU-side port interface ====
  reg  [31:0] cpu_addr = 0, cpu_din = 0;
  reg  [3:0]  cpu_be = 0;
  reg         cpu_valid = 0, cpu_write = 0;
  wire [31:0] cpu_dout;
  wire        cpu_ready, cpu_resp_valid;

  // ==== the device fabric (no device is under test here) ====
  reg  [7:0]  debug_status = 8'hA5;
  wire        device_io_wr, device_io_rd;
  wire [15:0] device_io_addr;
  wire  [7:0] device_io_din;
  reg   [7:0] device_io_dout = 8'hC3;
  reg         device_rd_wait = 1'b0;
  reg         device_rd_hold = 1'b0;
  reg         device_wr_wait = 1'b0;

  // ==== the strap inputs and the system-port outputs this bench reads ====
  reg  [3:0]  bios_set = 4'd0;
  // The OSD GDC Clock field (port 0x31 bit 7: 0 = the measured 2.5 MHz strap, 1 = 5 MHz).
  // Static here: this bench is not about the strap and an UNDRIVEN input is 0, which is
  // the machine's own state - tb_pc9821_bios_select and tb_pc9821_userdisk own the field.
  reg  gdc_clock_5m = 1'b0;
  reg  fdd_dip_fixed = 1'b1;   // the 0x00BE bit-2 FDD-mode switch at the measured unit's Fixed
  reg         triple_fault_reset = 1'b0;
  reg         cal_cdat = 0;
  reg  [6:0]  cfg_ram_mib = 7'd0;
  reg         cfg_seed_en = 1'b0;
  wire       sdip_seed_pulse;   // the machine-reset seed's one-shot (pc9821_iobus)
  reg         egc_gate = 1'b0;
  reg  [10:0] gdc_ff2_state = 11'd0;
  reg  [24:0] ps2_mouse = 25'd0;

  // ==== pc9821_iobus's own outputs (the ones this bench observes are named in the cases) ====
  wire [3:0]  top_bank;
  wire [1:0]  ems_state;
  wire        sound_extend, beep_mute;
  wire [1:0]  beep_vol;
  wire        fdc_irq;      // slave PIC IRQ11: the FDC at its 2HD window
  wire        fdc_irq10;    // slave PIC IRQ10: the SAME interrupt at its 2DD window
  wire        mouse_irq;
  wire [7:0]  win0_sel;
  wire       win0_sel_moved;   // pc9821_iobus's registered `win0_sel != 8'h08`
  wire        sys16m_en, ide_rom_enable, top_shadow_en, bios_ram_gate;
  wire ide_ram_gate;   // 0x1E8E's IDE work-RAM gate (the iobus drives it; unused here)
  wire        a20_enable, cpu_reset_req;
  wire [15:0] unmapped_writes, unmapped_reads, last_unmapped_port;
  wire  [7:0] post_code;
  wire        post_write;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg,
              egc_sft, egc_leng;
  wire        egc_shift_we;
  wire  [3:0] dbg_gate;
  wire  [7:0] dbg_itf_stage;
  wire [15:0] dbg_artic_hi, dbg_last_io_addr;
  wire  [7:0] dbg_last_io_data;
  wire        dbg_last_io_rd, dbg_last_io_wr;
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

  // ==== the floppy media seam (pc9821_fdd_media's side), modelled below ====
  wire [3:0]  fdd_present;
  // The mounted medium's write-protect state (Stage A). This bench has no media module, so
  // it drives the seam's answer directly; 0 = a writable medium, which is why the ST3 arms
  // below see no WP bit. Declared because pc9821_iobus is instantiated with .* and every
  // port of it must resolve here (tools/check_wiring.py enforces exactly this).
  wire [3:0]  fdd_wp = 4'b0000;
  wire       fdd_req_wr;   // pc9821_iobus's write leg (unused here: no write is issued)
  wire [7:0] fdd_din;
  wire       fdd_abort;
  wire [3:0]  fdd_chg = 4'd0;          // no media change: the FDC's ready-change tag
  wire        fdd_frame_tick = 1'b0;
  wire        fdd_req, fdd_req_hdr, fdd_adv;
  wire [1:0]  fdd_unit;
  wire  [7:0] fdd_c, fdd_h, fdd_r, fdd_n, fdd_idx;
  wire [7:0]  fdd_tc;   // pc9821_iobus's physical-track pair (pc9821_fdc media_tc/media_hd)
  wire        fdd_hd;
  wire        fdd_mf;
  wire        fdd_2hd;   // pc9821_iobus's media-mode pair (pc9821_fdc media_2hd/media_rpm)
  wire        fdd_rpm;
  wire        fdd_ready, fdd_rdy, fdd_hdrv, fdd_err;
  wire  [7:0] fdd_dout, fdd_hr, fdd_hn, fdd_hs;

  // ==== the uPD71071's bus-master memory port, modelled below ====
  wire [31:0] dma_mem_addr, dma_mem_din;
  wire [1:0]  dma_mem_gvwin;   // the DMAC's plane-window class (unused here)
  wire  [3:0] dma_mem_be;
  wire        dma_mem_req, dma_mem_we;
  reg         dma_mem_ready = 1'b0;
  reg  [31:0] dma_mem_dout = 32'd0;
  reg         dma_mem_resp_valid = 1'b0;

  wire [1:0] d8_bank;   // 0x063C bits 1-0 (the 0xD8000 bank select); unused here

  // P5: the device-bus chip selects are pc9821_iobus outputs now (its own one decode).
  // This bench drives no device select of its own, so they are named here for the wildcard
  // instantiation and left unused.
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1)) dut (
      .ide_unit0_present(1'b0),.*);

  // ==== STIMULUS ====
  // The port numbers this bench drives, named once.
  localparam [15:0] P_MSR_2HD  = 16'h0090,
                    P_DATA_2HD = 16'h0092,
                    P_DOR_2HD  = 16'h0094,
                    P_MSR_2DD  = 16'h00C8,
                    P_DATA_2DD = 16'h00CA,
                    P_DOR_2DD  = 16'h00CC,
                    P_STRAP    = 16'h00BE,
                    P_DMA_STAT = 16'h0011,
                    P_DMA_MASK = 16'h0015,
                    P_DMA_MODE = 16'h0017,
                    P_DMA_CLRFF= 16'h0019,
                    P_DMA_MASTER = 16'h001B;

  // The media model's own state: `ready` is high while no request is being served, `rdy`
  // is a LEVEL over the whole sector, `err`/`hdrv` are levels that stand until the next
  // request, and `adv` (the controller's DMA byte) consumes the byte at the pointer. The
  // byte at pointer k is (R ^ k), so a transferred sector is checkable byte for byte.
  reg        m_xfer, m_hdrv, m_err;
  reg [15:0] m_ptr;
  reg  [7:0] m_last_r, m_last_c, m_last_n;
  reg [15:0] m_reqs;
  // `xfer` DROPS when the sector's own 128<<N bytes are consumed, because the seam's
  // `ready` is `!xfer`: a model that never drops it leaves the NEXT request unable to
  // start at all (this bench's second failure - the 2HD case never got a sector).
  wire [15:0] m_secbytes = (m_last_n[7:4] != 4'd0) ? 16'd32768 : (16'd128 << m_last_n[3:0]);

  assign fdd_present = 4'b0001;      // one image, in unit 0
  assign fdd_ready = !m_xfer;
  assign fdd_rdy   = m_xfer;
  assign fdd_err   = m_err;
  assign fdd_hdrv  = m_hdrv;
  assign fdd_dout  = m_xfer ? (m_last_r ^ m_ptr[7:0]) : 8'h00;
  assign fdd_hr    = fdd_idx + 8'd1;
  assign fdd_hn    = 8'd3;
  assign fdd_hs    = 8'd2;

  always @(posedge clk) begin
    if (reset) begin
      m_xfer <= 1'b0; m_hdrv <= 1'b0; m_err <= 1'b0;
      m_ptr <= 16'd0; m_last_r <= 8'h00; m_last_c <= 8'h00; m_last_n <= 8'h00;
      m_reqs <= 16'd0;
    end else begin
      if (fdd_req) begin
        m_err  <= 1'b0;
        m_hdrv <= 1'b0;
        m_reqs <= m_reqs + 16'd1;
        if (fdd_req_hdr) m_hdrv <= 1'b1;
        else begin
          m_xfer   <= 1'b1;
          m_ptr    <= 16'd0;
          m_last_r <= fdd_r;
          m_last_c <= fdd_c;
          m_last_n <= fdd_n;
        end
      end
      if (m_xfer && fdd_adv) begin
        if (m_ptr + 16'd1 >= m_secbytes) m_xfer <= 1'b0;
        m_ptr <= m_ptr + 16'd1;
      end
    end
  end

  // The bus-master memory model: a WRITE per dma_mem_req (the floppy path only ever
  // stores), accepted the cycle it is presented, with the byte taken from the lane mem_be
  // names - the same lane decode pc9821_dmac uses, so a wrong lane shows up here.
  reg  [7:0] mem_bytes [0:65535];
  integer    mem_writes = 0;
  reg [31:0] mem_first_addr, mem_last_addr;
  reg  [7:0] mem_first_byte, mem_prev_byte;
  reg  [3:0] mem_bad_be = 4'h0;

  wire [7:0] mem_lane_byte = (dma_mem_addr[1:0] == 2'd0) ? dma_mem_din[7:0]   :
                             (dma_mem_addr[1:0] == 2'd1) ? dma_mem_din[15:8]  :
                             (dma_mem_addr[1:0] == 2'd2) ? dma_mem_din[23:16] :
                                                           dma_mem_din[31:24];

  always @(posedge clk) begin
    dma_mem_ready <= 1'b1;                     // the backend accepts in the request cycle
    if (!reset && dma_mem_req && dma_mem_we) begin
      mem_bytes[dma_mem_addr[15:0]] <= mem_lane_byte;
      if (mem_writes == 0) mem_first_addr <= dma_mem_addr;
      mem_last_addr <= dma_mem_addr;
      mem_first_byte <= (mem_writes == 0) ? mem_lane_byte : mem_first_byte;
      mem_prev_byte  <= mem_lane_byte;
      if (dma_mem_be !== (4'b0001 << dma_mem_addr[1:0])) mem_bad_be <= mem_bad_be | 4'h1;
      mem_writes = mem_writes + 1;
    end
  end

  task automatic clear_mem;
    integer q;
    begin
      for (q = 0; q < 65536; q = q + 1) mem_bytes[q] = 8'h00;
      mem_writes = 0;
      mem_bad_be = 4'h0;
    end
  endtask

  // One byte port access, the fabric's own contract: cpu_valid held until cpu_ready, the
  // byte on the addressed lane, and the address in cpu_addr[15:2].
  task automatic port_wr(input [15:0] p, input [7:0] d);
    reg [1:0] lane;
    begin
      lane = p[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, p[15:2], 2'b00};
      cpu_be = 4'b0001 << lane;
      cpu_din = {24'd0, d} << (lane * 8);
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

  reg [7:0] rd_val;
  task automatic port_rd(input [15:0] p);
    reg [1:0] lane;
    begin
      lane = p[1:0];
      @(negedge clk);
      cpu_addr = {16'd0, p[15:2], 2'b00};
      cpu_be = 4'b0001 << lane;
      cpu_write = 0;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      #1 rd_val = cpu_dout[{lane, 3'b000} +: 8];
      @(negedge clk);
      cpu_valid = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  // Wait for one of the DUT's level outputs, with a bound: a case that never completes
  // must be its own verdict, not the global watchdog's. `cyc` comes back at the cap when
  // the level never rose.
  //
  // THE LEVEL IS READ THROUGH THE HIERARCHY EVERY CYCLE, and that is not style: a task's
  // `input` is copied AT THE CALL and does not track a wire across time, so
  // `wait_until(dut.fdc_irq10, cyc)` froze the value it had when the task was entered and
  // ran to its cap while the level was already high - this bench's first failure.
  localparam integer WAIT_CAP = 20000;
  localparam integer W_IRQ11 = 0, W_IRQ10 = 1, W_DRQ = 2;
  integer cyc;

  task automatic wait_level(input integer which, output integer waited);
    integer reached;
    begin
      waited  = 0;
      reached = 0;
      while (!reached && (waited < WAIT_CAP)) begin
        case (which)
          W_IRQ11: reached = (dut.fdc_irq   === 1'b1);
          W_IRQ10: reached = (dut.fdc_irq10 === 1'b1);
          default: reached = (dut.fdc_drq   === 1'b1);
        endcase
        if (!reached) begin
          @(negedge clk);
          waited = waited + 1;
        end
      end
    end
  endtask

  // ---- the uPD71071, programmed through its own register window (the firmware's own
  // sequence: 0x1B master clear, address halves at 0x01+4*ch, bank at 0x21+2*((ch-1)&3),
  // count halves at 0x03+4*ch, mode at 0x17 = 0x04|ch (port-to-memory, contiguous, no
  // autoinit), 0x15 = ch to unmask. The bank port's odd mapping is pc9821_dmac's own
  // (NP2kai's `((port >> 1) + 1) & 3`: 0x23 is channel 2 and 0x25 is channel 3).
  task automatic dmac_arm(input [1:0] ch, input [23:0] addr, input [15:0] count);
    begin
      port_wr(P_DMA_MASTER, 8'h00);            // masks all four, zeroes addr/count
      port_wr(P_DMA_CLRFF,  8'h00);            // the low/high byte flip-flop
      port_wr(16'h0001 + {12'd0, ch, 2'b00}, addr[7:0]);
      port_wr(16'h0001 + {12'd0, ch, 2'b00}, addr[15:8]);
      port_wr(16'h0021 + {13'd0, ((ch - 2'd1) & 2'd3), 1'b0}, addr[23:16]);
      port_wr(16'h0003 + {12'd0, ch, 2'b00}, count[7:0]);
      port_wr(16'h0003 + {12'd0, ch, 2'b00}, count[15:8]);
      port_wr(P_DMA_MODE, {4'b0000, 2'b01, ch});   // din[3:2] = 01: port -> memory
      port_wr(P_DMA_MASK, {6'b000000, ch});        // din[2] = 0 clears that channel's mask
    end
  endtask

  // The command the data-path cases issue, at whichever window's data port they name.
  // READ DATA with MF=0: {hd,us}, C, H, R, N, EOT, GPL, DTL (NP2kai FDC_ReadData, :461-474).
  task automatic read_data_cmd(input [15:0] data_port, input [7:0] unit_head,
                               input [7:0] c, input [7:0] h, input [7:0] r,
                               input [7:0] n, input [7:0] eot);
    begin
      port_wr(data_port, 8'h06);
      port_wr(data_port, unit_head);
      port_wr(data_port, c);
      port_wr(data_port, h);
      port_wr(data_port, r);
      port_wr(data_port, n);
      port_wr(data_port, eot);
      port_wr(data_port, 8'h00);   // GPL
      port_wr(data_port, 8'h00);   // DTL
    end
  endtask

  // Drain the seven-byte result and check the two bytes a TC-terminated READ DATA pins:
  // ST0 = {hd<<2|us} and R = 1 (NP2kai fdc_dataread forces R on the terminal count,
  // io/fdc.c:925-932).
  task automatic check_result_tc(input [15:0] data_port, input [8*40-1:0] case_name);
    begin
      port_rd(data_port);
      if (rd_val !== 8'h00)
        $fatal(1, "%0s: result ST0 = %02x, expected 00 (unit 0, head 0, success)",
               case_name, rd_val);
      port_rd(data_port);   // ST1
      port_rd(data_port);   // ST2
      port_rd(data_port);   // C
      port_rd(data_port);   // H
      port_rd(data_port);
      if (rd_val !== 8'h01)
        $fatal(1, "%0s: result R = %02x, expected 01 (the DMA terminal count forces R=1, NP2kai fdc_dataread :925-932)",
               case_name, rd_val);
      port_rd(data_port);   // N - drains the result phase
    end
  endtask

// ==== CHECKS ====

  initial begin
    #80_000_000;
    $fatal(1, "TB_PC9821_FDC_2DD_BANK: watchdog timeout (no verdict reached)");
  end

  initial begin
    reset = 1;
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);
    clear_mem;

    // ------------------------------------------------------------------ 11: the reset state
    // FIRST, because it is the precondition the boot golden rests on: chgreg resets to 3
    // (NP2kai fdc_reset `fdc.chgreg = 3`, io/fdc.c:1159), so at reset the 2HD window answers
    // and the 2DD one is dead - which is why the ITF's own 0xC8 probes (BANK4 0x66A6/0x66CA/
    // 0x66F5) take the 0x90 branch and CYCLES used=930542 cannot move.
    port_rd(P_STRAP);
    // The read: docs/probes/FDMODE-XE10.TXT `PORT 00BE=FF` - bits 7:2 read 1 (bit 2 is the
    // fixed-mode DIP; NP2kai's fdc_ibe answers 0xF8|chgreg, bit 2 clear - outranked).
    if (rd_val !== 8'hFF)
      $fatal(1, "boot_golden_precondition: 0x00BE reads %02x at reset, expected FF = 0xFC|3 (docs/probes/FDMODE-XE10.TXT PORT 00BE=FF; chgreg 3 per NP2kai fdc_reset :1159)",
             rd_val);
    port_rd(P_MSR_2HD);
    if (rd_val !== 8'h80)
      $fatal(1, "boot_golden_precondition: 0x90 reads %02x at reset, expected 80 (RQM, idle)",
             rd_val);
    port_rd(P_MSR_2DD);
    if (rd_val !== 8'hFF)
      $fatal(1, "boot_golden_precondition: 0xC8 reads %02x at reset, expected FF - the 2DD window must be gated out with chgreg=3, or the boot path moves",
             rd_val);

    // ------------------------------------------------------------------ 1: strap_readback
    // The read answers chgreg[1:0] with every bit above them one (the capture's FF at
    // chgreg 3), so clearing bit 0 (the 2DD interface) must read back as 0xFE.
    port_wr(P_STRAP, 8'h02);
    port_rd(P_STRAP);
    if (rd_val !== 8'hFE)
      $fatal(1, "strap_readback: after `out 0x00BE,0x02` the read gives %02x, expected FE = 0xFC|2 (bits 1:0 as written, NP2kai fdc_ibe; bits 7:2 one, docs/probes/FDMODE-XE10.TXT)",
             rd_val);
    if (dut.fdc_strap_2hd !== 1'b0)
      $fatal(1, "strap_readback: the exported strap is %b after 0x00BE <- 0x02, expected 0", dut.fdc_strap_2hd);

    // ------------------------------------------------------------------ 2: msr_2dd_window
    // The same register file, one door over: NP2kai's fdc_i90 returns fdc.status, and its
    // handler table is bound at both 0x0090 and 0x00C8 with the 0x00f9 mask, so
    // (port >> 1) & 3 indexes the SAME MSR in either bank.
    port_rd(P_MSR_2DD);
    if (rd_val !== 8'h80)
      $fatal(1, "msr_2dd_window: with the strap at 0x02, 0xC8 reads %02x, expected the controller's own idle MSR 0x80 (NP2kai fdc_i90 :1035-1043)",
             rd_val);

    // ------------------------------------------------------------------ 3: command_2dd_window
    // RECALIBRATE (0x07, one parameter) written to the 2DD data port must reach the one
    // command decoder: the MSR shows the busy bit of unit 0 (the drive the command claimed)
    // with DIO clear, and then completes. The busy nibble is the property asserted; RQM/CB
    // during the delay are the model's (0x11: no RQM while it cannot take a byte,
    // tb_pc9821_fdc_conform seek_then_sis) where NP2kai shows 0x81.
    port_wr(P_DATA_2DD, 8'h07);
    port_wr(P_DATA_2DD, 8'h00);
    port_rd(P_MSR_2DD);
    if ((rd_val & 8'h4F) !== 8'h01)
      $fatal(1, "command_2dd_window: MSR after RECALIBRATE on 0xCA reads %02x, expected the busy bit of unit 0 with DIO clear",
             rd_val);
    wait_level(W_IRQ10, cyc);
    if (cyc >= WAIT_CAP)
      $fatal(1, "command_2dd_window: the 2DD-window RECALIBRATE never completed (no IRQ10 within %0d cycles)", WAIT_CAP);

    // ------------------------------------------------------------------ 4: irq_dest_2dd
    // ONE controller, TWO interrupts: with bit 0 clear the completion goes to IRQ10 and NOT
    // IRQ11 (NP2kai fdc_intwait `if (fdc.chgreg & 1) pic_setirq(0x0b) else pic_setirq(0x0a)`,
    // io/fdc.c:43-56).
    if (fdc_irq !== 1'b0)
      $fatal(1, "irq_dest_2dd: fdc_irq (IRQ11) is high with the strap selecting the 2DD window - the mux is not applied");
    if (fdc_irq10 !== 1'b1)
      $fatal(1, "irq_dest_2dd: fdc_irq10 (IRQ10) is low with the strap selecting the 2DD window");
    // SENSE INTERRUPT STATUS drains it, and the ST0 is the deferred completion's own
    // SENSE INTERRUPT STATUS drains it, and the ST0 is RECALIBRATE's own completion. This
    // bench wires ONE image in unit 0 (fdd_present = 4'b0001 above), so the drive is READY
    // and NP2kai's FDC_Recalibrate sets int_stat = us | SE = 0x20 (io/fdc.c:527-563) - NOT
    // the drive-not-ready class SE|IC0|NR (0x68), which is what a drive with NO medium
    // answers (the per-state classes: SE|NR = 0x28 for an equipped drive with no diskette,
    // SE|IC0|NR = 0x68 for a unit whose READY is never asserted - the plan's W1/W2).
    // tb_pc9821_fdc_conform pins those with media_present = 2'b00, which is where they
    // belong; this arm used to expect the IC0 class here too, against a media-present drive.
    port_wr(P_DATA_2DD, 8'h08);
    port_rd(P_DATA_2DD);
    if (rd_val !== 8'h20)
      $fatal(1, "irq_dest_2dd: SENSE INTERRUPT STATUS on 0xCA answered ST0 %02x, expected 20 (SE|us, RECALIBRATE on a ready drive)", rd_val);
    port_rd(P_DATA_2DD);
    @(negedge clk); @(negedge clk);
    if (fdc_irq10 !== 1'b0)
      $fatal(1, "irq_dest_2dd: IRQ10 stayed high after SENSE INTERRUPT STATUS drained the completion");

    // ------------------------------------------------------------------ 5: irq_dest_2hd
    // The other side of the mux, which is what proves a SELECT and not just a second line.
    port_wr(P_STRAP, 8'h03);
    port_wr(P_DATA_2HD, 8'h07);
    port_wr(P_DATA_2HD, 8'h00);
    wait_level(W_IRQ11, cyc);
    if (cyc >= WAIT_CAP)
      $fatal(1, "irq_dest_2hd: the 2HD-window RECALIBRATE never completed (no IRQ11 within %0d cycles)", WAIT_CAP);
    if (fdc_irq10 !== 1'b0)
      $fatal(1, "irq_dest_2hd: IRQ10 is high with the strap back at 0x03 - the strap does not select the interrupt");
    port_wr(P_DATA_2HD, 8'h08);
    port_rd(P_DATA_2HD);
    if (rd_val !== 8'h20)
      $fatal(1, "irq_dest_2hd: SENSE INTERRUPT STATUS on 0x92 answered ST0 %02x, expected 20 (SE|us, ready-drive RECALIBRATE)", rd_val);
    port_rd(P_DATA_2HD);
    @(negedge clk); @(negedge clk);

    // ------------------------------------------------------------------ 6: dma_ch3_2dd
    // The media path over the strap's own channel: READ DATA on the 2DD window moves the
    // sector over DMA channel 3, and the engine's OWN status port proves the channel (its
    // terminal-count nibble is one bit per channel: bit 2 = ch2, bit 3 = ch3).
    port_wr(P_STRAP, 8'h02);
    clear_mem;
    dmac_arm(2'd3, 24'h002000, 16'd127);
    read_data_cmd(P_DATA_2DD, 8'h00, 8'h00, 8'h00, 8'h01, 8'h00, 8'h01);
    wait_level(W_IRQ10, cyc);
    if (cyc >= WAIT_CAP)
      $fatal(1, "dma_ch3_2dd: the 2DD-window READ DATA never completed within %0d cycles (DRQ on channel 3 never moved a byte?)", WAIT_CAP);
    // The terminal count and the command's completion are the SAME cycle, so the
    // engine's final memory write is still in flight when the interrupt appears:
    // let it settle before counting bytes.
    repeat (16) @(negedge clk);
    if (mem_writes != 128)
      $fatal(1, "dma_ch3_2dd: %0d bytes reached memory, expected 128 (one 128<<0 byte sector)", mem_writes);
    if (mem_bytes[16'h2000] !== 8'h01 || mem_bytes[16'h2001] !== 8'h00)
      $fatal(1, "dma_ch3_2dd: the sector's first bytes are %02x %02x, expected 01 00 (media byte = R^k with R=1)",
             mem_bytes[16'h2000], mem_bytes[16'h2001]);
    if (mem_bytes[16'h207F] !== 8'h7E)
      $fatal(1, "dma_ch3_2dd: the sector's last byte is %02x, expected 7E (R^127)", mem_bytes[16'h207F]);
    if (mem_bad_be != 4'h0)
      $fatal(1, "dma_ch3_2dd: mem_be disagreed with the address's lane on at least one byte");
    port_rd(P_DMA_STAT);
    if (rd_val !== 8'h08)
      $fatal(1, "dma_ch3_2dd: the DMA status port reads %02x, expected 08 - channel 3's terminal count (bit 2 = ch2, bit 3 = ch3). The sector moved on the WRONG channel",
             rd_val);
    check_result_tc(P_DATA_2DD, "dma_ch3_2dd");

    // ------------------------------------------------------------------ 7: dma_ch2_2hd
    // The regression guard: the same command on the 2HD window still uses channel 2, so the
    // select did not simply move the FDC's bytes to one hard-wired channel.
    port_wr(P_STRAP, 8'h03);
    clear_mem;
    dmac_arm(2'd2, 24'h003000, 16'd127);
    read_data_cmd(P_DATA_2HD, 8'h00, 8'h00, 8'h00, 8'h01, 8'h00, 8'h01);
    wait_level(W_IRQ11, cyc);
    if (cyc >= WAIT_CAP)
      $fatal(1, "dma_ch2_2hd: the 2HD-window READ DATA never completed within %0d cycles", WAIT_CAP);
    // The terminal count and the command's completion are the SAME cycle, so the
    // engine's final memory write is still in flight when the interrupt appears:
    // let it settle before counting bytes.
    repeat (16) @(negedge clk);
    if (mem_writes != 128)
      $fatal(1, "dma_ch2_2hd: %0d bytes reached memory, expected 128", mem_writes);
    if (mem_bytes[16'h3000] !== 8'h01 || mem_bytes[16'h307F] !== 8'h7E)
      $fatal(1, "dma_ch2_2hd: the sector bytes are %02x..%02x, expected 01..7E",
             mem_bytes[16'h3000], mem_bytes[16'h307F]);
    port_rd(P_DMA_STAT);
    if (rd_val !== 8'h04)
      $fatal(1, "dma_ch2_2hd: the DMA status port reads %02x, expected 04 - channel 2's terminal count", rd_val);
    check_result_tc(P_DATA_2HD, "dma_ch2_2hd");

    // ------------------------------------------------------------------ 8: dma_chann_qualifier
    // The other channel's strobe cannot move these bytes: with the strap at 2DD, only
    // channel 2 is unmasked, and its DRQ line must stay silent while the controller holds
    // its byte for channel 3 - so no byte reaches memory and the transfer does not advance.
    port_wr(P_STRAP, 8'h02);
    clear_mem;
    dmac_arm(2'd2, 24'h004000, 16'd127);      // channel 2 armed; channel 3 still masked
    read_data_cmd(P_DATA_2DD, 8'h00, 8'h00, 8'h00, 8'h01, 8'h00, 8'h01);
    wait_level(W_DRQ, cyc);                // the controller does raise its own DRQ
    if (cyc >= WAIT_CAP)
      $fatal(1, "dma_chann_qualifier: the FDC never raised DRQ at all");
    repeat (2000) @(negedge clk);
    if (mem_writes != 0)
      $fatal(1, "dma_chann_qualifier: %0d bytes moved over channel 2 while the strap selects channel 3 - the strobe is not qualified by the channel",
             mem_writes);
    if (dut.fdc_drq_ch2 !== 1'b0)
      $fatal(1, "dma_chann_qualifier: the controller's channel-2 DRQ is high with the strap selecting the 2DD window");
    if (dut.fdc_drq_ch3 !== dut.fdc_drq)
      $fatal(1, "dma_chann_qualifier: the controller's channel-3 DRQ does not follow its own DRQ");
    // Leave the controller idle for the rest of the bench: a full reset drops the stuck
    // command, and the cases that follow are all pure port reads.
    reset = 1;
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);

    // ------------------------------------------------------------------ 9: the gate
    // CAPTURE-PENDING, and it follows NP2KAI: the unselected window answers 0xFF and its
    // writes are dropped (`if (((port >> 4) ^ fdc.chgreg) & 1) return 0xff;`, io/fdc.c:1040/
    // 1050/1068, and the same test at the top of fdc_o92/fdc_o94 :975/:996). qemu-pc98
    // ALIASES instead (both windows route to one handler, hw/block/pc98-fdc.c:2808-2818) and
    // MAME aliases with a TODO saying it should be gated (pc9801.cpp:567-569). A capture
    // reading 0x90/0xC8 before and after `out 0x00BE,0x02` settles it either way.
    port_wr(P_STRAP, 8'h02);
    port_rd(P_MSR_2HD);
    if (rd_val !== 8'hFF)
      $fatal(1, "hd_window_dead_under_2dd_strap (NP2KAI; qemu/MAME alias): with the strap at 0x02, 0x90 reads %02x, expected FF",
             rd_val);
    // A write to the dead window must not reach the controller either: RECALIBRATE + its
    // unit byte at 0x92, then the MSR at 0xC8 must still be idle and no interrupt may appear.
    port_wr(P_DATA_2HD, 8'h07);
    port_wr(P_DATA_2HD, 8'h01);
    repeat (2000) @(negedge clk);
    if (fdc_irq10 !== 1'b0 || fdc_irq !== 1'b0)
      $fatal(1, "hd_window_dead_under_2dd_strap (NP2KAI; qemu/MAME alias): a command written to 0x92 with the strap at 0x02 reached the controller (an IRQ appeared)");
    port_rd(P_MSR_2DD);
    if (rd_val !== 8'h80)
      $fatal(1, "hd_window_dead_under_2dd_strap (NP2KAI; qemu/MAME alias): the controller's MSR at 0xC8 is %02x after a write to the dead 0x92 window, expected the idle 0x80",
             rd_val);
    // And the mirror image: with the strap back at 2HD the 2DD window is the dead one.
    port_wr(P_STRAP, 8'h03);
    port_rd(P_MSR_2DD);
    if (rd_val !== 8'hFF)
      $fatal(1, "hd_window_dead_under_2dd_strap (NP2KAI; qemu/MAME alias): with the strap at 0x03, 0xC8 reads %02x, expected FF", rd_val);

    // ------------------------------------------------------------------ 10: control port byte
    // CAPTURE-PENDING, and it follows NP2KAI's fdc_i94: `ret = 0x40; if (!(port & 0x10))
    // { ret |= 0x20; ret |= 0x10; }` (io/fdc.c:1064-1078) - the 2DD door at 0xCC advertises
    // DMA and ready, the 2HD door at 0x94 does not, so 0x94 keeps the 0x44 this machine has
    // been MEASURED at (docs/probes/PORTS.TXT) and 0xCC answers 0x74. QEMU-PC98 DISAGREES:
    // its FDSTAT_DMA (0x20) is set at 0x94 and not at 0xcc (hw/block/pc98-fdc.c:2816-2827).
    // MAME agrees with NP2kai (pc9801.cpp:571-580). A capture reading 0x94 and 0xCC back to
    // back settles it; this assertion names both readings so a flip is a named change.
    port_rd(P_DOR_2HD);
    if (rd_val !== 8'h44)
      $fatal(1, "control_port_byte_2dd (NP2KAI: 0x94=0x44, 0xCC=0x74; QEMU: 0x94 gets 0x20): 0x94 reads %02x, expected the machine's measured 44",
             rd_val);
    port_wr(P_STRAP, 8'h02);
    port_rd(P_DOR_2DD);
    if (rd_val !== 8'h74)
      $fatal(1, "control_port_byte_2dd (NP2KAI: 0x94=0x44, 0xCC=0x74; QEMU: 0x94 gets 0x20): 0xCC reads %02x, expected 74 (0x40 | DMA 0x20 | ready 0x10 | internal-priority 0x04)",
             rd_val);

    // ------------------------------------------------------------------ 11: the reset state again
    // The last word is the golden's: from a cold reset the strap is 3, the 2HD window
    // answers and the 2DD one is dead - so every ITF probe that branches to 0xC8 on this
    // machine takes the 0x90 branch, and `CYCLES used=930542` cannot move.
    reset = 1;
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);
    port_rd(P_STRAP);
    if (rd_val !== 8'hFF)
      $fatal(1, "boot_golden_precondition: 0x00BE reads %02x after a reset, expected FF (docs/probes/FDMODE-XE10.TXT)", rd_val);
    port_rd(P_MSR_2DD);
    if (rd_val !== 8'hFF)
      $fatal(1, "boot_golden_precondition: 0xC8 reads %02x after a reset, expected FF", rd_val);

    // ------------------------------------------------------------------ 12: the FDD-mode switch
    // 0x00BE bit 2 is the FDD-mode switch, both positions real (MAME pc9801.cpp fdc_mode_r
    // `(m_dsw3->read() & 3) << 2`, DSW3:1 Fixed / Auto-Detection). Fixed reads the measured
    // unit's FF (docs/probes/FDMODE-XE10.TXT), Auto FB (NP2kai fdc_ibe `(fdc.chgreg & 3) | 8 |
    // 0xf0`). POST samples a switch, so the read follows the input only across a reset.
    fdd_dip_fixed = 1'b0;
    repeat (4) @(negedge clk);
    port_rd(P_STRAP);
    if (rd_val !== 8'hFF)
      $fatal(1, "fdd_mode_switch: 0x00BE reads %02x after the switch moved to Auto WITHOUT a reset, expected FF (sampled at reset only)", rd_val);
    reset = 1;
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);
    port_rd(P_STRAP);
    if (rd_val !== 8'hFB)
      $fatal(1, "fdd_mode_switch: 0x00BE reads %02x at Auto after a reset, expected FB (bit 2 clear, NP2kai fdc_ibe)", rd_val);
    port_rd(16'h00BF);
    if (rd_val !== 8'hFB)
      $fatal(1, "fdd_mode_switch: 0x00BF reads %02x at Auto, expected FB (the pair reads alike)", rd_val);
    port_wr(P_STRAP, 8'h02);
    port_rd(P_STRAP);
    if (rd_val !== 8'hFA)
      $fatal(1, "fdd_mode_switch: 0x00BE reads %02x at Auto after `out 0x00BE,0x02`, expected FA", rd_val);
    fdd_dip_fixed = 1'b1;
    reset = 1;
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);
    port_rd(P_STRAP);
    if (rd_val !== 8'hFF)
      $fatal(1, "fdd_mode_switch: 0x00BE reads %02x back at Fixed after a reset, expected FF", rd_val);

// ==== VERDICT ====
    $display("TB_PC9821_FDC_2DD_BANK: PASS");
    $finish;
  end
endmodule
