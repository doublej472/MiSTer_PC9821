`timescale 1ns/1ps

// Boots the AUTHENTIC firmware pack against a user-supplied disk image that is
// served sector-by-sector over the MiSTer img_* handshake.  Unlike the
// deterministic IPL harness, this serves *any* LBA from a loaded image so a
// real NEC IPL + FAT16 boot chain (and a DOS load) can run.
//
// The image is loaded from "userdisk.mem" (one 16-bit hex word per line,
// little-endian byte order, 256 words per 512-byte sector).
`ifndef IMG_WORDS
`define IMG_WORDS 2097152
`endif
// ==== WHAT THIS PROVES ====
// TB_PC9821_USERDISK:
// The AUTHENTIC firmware against a user IDE image reaches the IPL at 1FC0:0000, and before that it passes the CG-window configuration record asserted by the ITF's own writes (no repair store at 0x811, the accept-only stage 0x05). That is a control-flow criterion and cannot see wrong sector data; this is the only tier that exercises the disk at all, it is skipped when PC98_USERDISK is unset, and its instruments run during the run rather than on a timeout path.


module tb_pc9821_userdisk;
  localparam int IMG_WORDS = `IMG_WORDS;
  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;
  reg reset = 1;
  reg hps_apply_reset = 0;
  // Fixed BCD RTC (2026-09-12 12:34:56, Friday) so the calendar path is
  // deterministic: {weekday, year, month, day, hour, minute, second}.
  wire [55:0] rtc = 56'h05_26_09_12_12_34_56;

  reg ioctl_download = 0, ioctl_wr = 0;
  reg [15:0] ioctl_index = 0;
  reg [26:0] ioctl_addr = 0;
  reg [15:0] ioctl_dout = 0;
  wire ioctl_wait;

  reg [10:0] ps2_key = 0;
  reg [24:0] ps2_mouse = 25'd0;   // hps_io's packet: {toggle, Y, X, flags[7:3], M, R, L}
  reg img_mounted = 0, img_readonly = 1;
  reg [63:0] img_size = 0;
  // +FDD_FILE=<path>: a floppy image (D88/HDM/FDD) on hps_io slot 1 (FDD1), served by this host
  // model's third leg from the file; the guest's writes land in an in-memory overlay.
  wire [31:0] fdd_lba;
  wire [5:0]  fdd_blk_cnt;
  wire        fdd_rd, fdd_wr;
  reg         fdd_ack = 0;
  wire [15:0] fdd_buff_din;
  reg         fdd_mounted = 0;
  // +FDD2_FILE=<path>: the second floppy (FDD2, hps_io's fdd1 slot), served the same way.
  wire [31:0] fdd1_lba;
  wire [5:0]  fdd1_blk_cnt;
  wire        fdd1_rd, fdd1_wr;
  reg         fdd1_ack = 0;
  wire [15:0] fdd1_buff_din;
  reg         fdd1_mounted = 0;
  reg  [63:0] fdd1_size = 0;
  // +CD_FILE=<path>: the CD-ROM's image (ISO or PCD, tools/cue2pcd.py) on hps_io slot 4, served
  // by this host model's second leg (the leg that once served the removed second hard disk).
  // Only in a build with -DUSERDISK_CD (USERDISK_CD=1 for run_userdisk.sh), which builds
  // pc9821_system with CDROM_EN: the CD is bank 1's master; the disk is bank 0's in every build.
  reg hdd1_mounted = 0;
  reg [63:0] hdd1_size = 0;
  wire [31:0] hdd1_lba;
  wire [5:0] hdd1_blk_cnt;
  wire hdd1_rd;
  wire hdd1_wr = 1'b0;
  reg hdd1_ack = 0;
  wire [15:0] hdd1_buff_din = 16'd0;
`ifdef USERDISK_CD
  localparam TB_CDROM = 1'b1;
`else
  localparam TB_CDROM = 1'b0;
`endif
  // The run-time SDRAM_CLK phase instrument (-DUSERDISK_SDPH): its guest ports and its scan-clock
  // engine, against a PLL model that counts the steps (no real phase moves in simulation).
`ifdef USERDISK_SDPH
  localparam TB_SDPH = 1'b1;
`else
  localparam TB_SDPH = 1'b0;
`endif
  wire sdph_req, sdph_up, sdph_ack, sdph_fault;
  wire [31:0] img_lba;
  wire [5:0] img_blk_cnt;
  wire img_rd, img_wr;
  reg img_ack = 0;
  reg [12:0] img_buff_addr = 0;
  reg [15:0] img_buff_din = 0;
  wire [15:0] img_buff_dout;
  reg img_buff_wr = 0;

  wire [31:0] ext_mem0_addr, ext_mem0_din;
  reg [31:0] ext_mem0_dout = 0;
  wire [3:0] ext_mem0_be;
  wire [7:0] ext_mem0_burstcount;
  wire ext_mem0_valid, ext_mem0_write;
  // The SDRAM controller's THIRD port: the 86-PCM sample buffer (pc9821_pcm86_buf, one 32-bit
  // word per request). Left unconnected it never answers, the buffer's write FIFO fills, and the
  // back-pressured 0xA46C REP OUTSB stalls the CPU for good - a guest that streams PCM (the
  // Policenauts logo, through AVSDRV.SYS) hung here with zero retirement while the hardware ran
  // on. Modelled as an always-ready 32 KiB memory with a one-cycle read response.
  wire [31:0] ext_mem2_addr, ext_mem2_din;
  wire [3:0]  ext_mem2_be;
  wire [7:0]  ext_mem2_burstcount;
  wire        ext_mem2_valid, ext_mem2_write;
  reg  [31:0] ext_mem2_dout = 32'd0;
  reg         ext_mem2_resp_valid = 1'b0;
  reg  [31:0] pcm_mem [0:8191];
`ifdef USERDISK_SDPH
  // The engine on clk_sys (the card runs it on the 50 MHz reference) and a DPS model: PHASEDONE
  // falls 3 clocks after a PHASEEN rise and rises 8 later, and the model counts the net steps.
  wire sdph_pen, sdph_updn;
  wire [4:0] sdph_cntsel;
  reg  sdph_pdone = 1'b1, sdph_pen_d = 1'b0;
  integer sdph_busy = 0, sdph_steps = 0, sdph_pulses = 0;
  pc9821_sdram_dps sdph_dps (
      .clk(clk_sys), .step_req_async(sdph_req), .step_up_async(sdph_up),
      .phase_done_async(sdph_pdone), .phase_en(sdph_pen), .updn(sdph_updn), .cntsel(sdph_cntsel),
      .step_ack(sdph_ack), .fault(sdph_fault));
  always @(posedge clk_sys) begin
    sdph_pen_d <= sdph_pen;
    if (sdph_pen && !sdph_pen_d) begin
      sdph_busy <= 11;
      sdph_pulses <= sdph_pulses + 1;
    end else if (sdph_busy != 0) begin
      sdph_busy <= sdph_busy - 1;
      if (sdph_busy == 8) sdph_pdone <= 1'b0;
      if (sdph_busy == 1) begin
        sdph_pdone <= 1'b1;
        sdph_steps <= sdph_updn ? sdph_steps + 1 : sdph_steps - 1;
      end
    end
  end
  final $display("SDPH: pulses=%0d net_steps=%0d fault=%0d", sdph_pulses, sdph_steps, sdph_fault);
`else
  assign sdph_ack = 1'b0;
  assign sdph_fault = 1'b0;
`endif

  always @(posedge clk_sys) begin
    ext_mem2_resp_valid <= 1'b0;
    if (ext_mem2_valid) begin
      if (ext_mem2_write) begin
        for (int b = 0; b < 4; b++)
          if (ext_mem2_be[b]) pcm_mem[ext_mem2_addr[14:2]][b*8 +: 8] <= ext_mem2_din[b*8 +: 8];
      end else begin
        ext_mem2_dout <= pcm_mem[ext_mem2_addr[14:2]];
        ext_mem2_resp_valid <= 1'b1;
      end
    end
  end
  // ---- SDRAM-side realism, OFF BY DEFAULT ------------------------------  //
  // Two properties of the default model are measurement LIMITS rather than
  // design facts, and they are the two the hardware does not share:
  //
  //   1. it answers every request in the same cycle, so no handshake that depends
  //      on the backend being slow can ever be seen to fail; and
  //   2. it stops at the firmware reserve's end, so with the 32 MiB guest the
  //      GVRAM above it is NOT MODELLED AT ALL - its writes are dropped and its
  //      reads return all-ones. In hardware the GVRAM is real SDRAM on the same
  //      requester as the CPU, which is exactly where a graphics-wave bug hides.
  //
  //   +SDRAM_FULL=1          model the real extent: guest RAM + pack + GVRAM
  //   +SDRAM_LATENCY=<n>     hold the accept n cycles before asserting ready
  //
  // With both unset the model behaves byte-for-byte as it did.
  integer    sdram_latency = 0;
  integer    sdram_full    = 0;
  localparam [31:0] RAM_TOP_MAX = 32'h0220_0000;   // the array's own end below
  reg [31:0] sdram_top = 32'h0211_0000;
  // The EMS page window (0x043F state 0x22) is served from pack_base + PACK_BYTES +
  // 0x48000, for 64 KiB (pc9821_memory_subsystem's ems_page_base). The model must cover it
  // EVEN WITHOUT +SDRAM_FULL, or the window's stores are dropped and its reads return
  // all-ones, and the ITF's own 64 KiB fill/verify (BANK4@0xF82C7) fails as EMS ERROR on a
  // core that is correct.
  //
  // The TOP-WINDOW SHADOW sits 0x10000 past the page
  // (fw_shadow_base = pack_base + PACK_BYTES + 0x58000, 32 KiB), so the bound must reach
  // 0x160000 above the guest base or every shadow read returns all-ones and a dirty shadow
  // turns the ITF's own 0xF8000 fetch into the CS=0 runaway (measured: the fetch
  // at 0xF9A10 filled 0xFFFF_FFFF instead of the bank's code).
  //
  // THE BLOCK ABOVE THE PACK IS NOW GVRAM FIRST. The GVRAM moved back into SDRAM and takes
  // the 256 KiB directly above the pack; the 86-PCM buffer sits a further 32 KiB past it
  // (guest_ram_bytes + 0x140000), and the EMS page and shadow were pushed above that. So the
  // whole span is pack (0x100000) + GVRAM (0x40000) + PCM (0x8000) + EMS (0x10000) +
  // shadow (0x8000) = 0x160000, and the model bound must reach it.
  function automatic [31:0] ram_size_model_top;
    reg [31:0] top;
    begin
      top = ram_size_base() + 32'h0016_0000;
      ram_size_model_top = (top > RAM_TOP_MAX) ? RAM_TOP_MAX : top;
    end
  endfunction
  function automatic [31:0] ram_size_extent;
    reg [31:0] base;
    begin
      case (ram_size)
        3'd0: base = 32'h0010_0000;
        3'd1: base = 32'h0020_0000;
        3'd2: base = 32'h0040_0000;
        3'd3: base = 32'h0080_0000;
        3'd4: base = 32'h0100_0000;
        3'd5: base = 32'h0200_0000;
        3'd6: base = 32'h0400_0000;
        default: base = 32'h0600_0000;
      endcase
      // + the 1 MiB pack at pack_base, + GVRAM's 256 KiB, PCM, EMS page and shadow above it
      base = base + 32'h0010_0000 + 32'h0006_0000;
      ram_size_extent = (base > RAM_TOP_MAX) ? RAM_TOP_MAX : base;
    end
  endfunction
  initial begin
    void'($value$plusargs("SDRAM_LATENCY=%d", sdram_latency));
    void'($value$plusargs("SDRAM_FULL=%d", sdram_full));
      if ($test$plusargs("CARD_BACKEND")) card_backend = 1;
  end
  // The size-derived bounds are latched at the FIRST CLOCK, not in an initial
  // block: Verilog does not order initial blocks, and ram_size is set by a
  // plusarg read in another one. Reading it in an initial gave pack_lo=0x02000000
  // on a 16 MiB run - a watchpoint watching the wrong reserve, reporting zero
  // writes because the real reserve was below its bound.
  reg sdram_cfg_done = 1'b0;
  always @(posedge clk_sys) begin
    if (!sdram_cfg_done) begin
      sdram_cfg_done <= 1'b1;
      sdram_pack_lo  <= ram_size_base();
      sdram_top <= (sdram_full != 0) ? ram_size_extent() : ram_size_model_top();
    end
  end
  // The firmware reserve's own base and end for THIS run's size. The reserve is
  // pack_base == guest_ram_bytes, so the bound moves with the OSD size and a
  // watchpoint has to move with it: a store into [pack_lo, pack_lo+1MiB) is a
  // store into the firmware, and the core is supposed to send the BIOS-top
  // shadow there and nothing else.
  function automatic [31:0] ram_size_base;
    begin
      case (ram_size)
        3'd0: ram_size_base = 32'h0010_0000;
        3'd1: ram_size_base = 32'h0020_0000;
        3'd2: ram_size_base = 32'h0040_0000;
        3'd3: ram_size_base = 32'h0080_0000;
        3'd4: ram_size_base = 32'h0100_0000;
        3'd5: ram_size_base = 32'h0200_0000;
        3'd6: ram_size_base = 32'h0400_0000;
        default: ram_size_base = 32'h0600_0000;
      endcase
    end
  endfunction
  reg [31:0] sdram_pack_lo = 32'h0200_0000;
  integer    pack_writes = 0;
  integer    above_ram_writes = 0;
  always @(posedge clk_sys) begin
    if (ext_mem0_valid && ext_mem0_ready && ext_mem0_write) begin
      if (ext_mem0_addr >= sdram_pack_lo) begin
        above_ram_writes <= above_ram_writes + 1;
        if (ext_mem0_addr < sdram_pack_lo + 32'h0010_0000) begin
          pack_writes <= pack_writes + 1;
          if (pack_writes < 10 || (pack_writes % 1000) == 0)
            $display("PACKWR n=%0d addr=%08x be=%x data=%08x", pack_writes,
                     ext_mem0_addr, ext_mem0_be, ext_mem0_din);
        end
      end
    end
  end
  reg       ext_mem0_ready_r = 1'b1;
  reg [7:0] lat_cnt = 8'd0;
  // A READ IS ANSWERED ONE BEAT PER WORD, `ext_mem0_burstcount` of them, exactly as
  // src/memory/sdram.v answers a burst (sdram.v:7). The GVRAM's write-combining buffer
  // prefetches a short run of consecutive words on a miss (pc9821_gvram.sv, the
  // coalescer), so a model that answered ONE beat per REQUEST - which is all this tier
  // needed while cb_burstcount was hard-wired to 1 - leaves the buffer's fill waiting for
  // beats that never come. The rest of the burst walks the address, and the controller is
  // ONE transaction at a time (sdram.v:1169, `IDLE: if (~nce) begin`), so `ready` stays low until its last beat.
  reg [7:0]  rd_left = 8'd0;
  reg [31:0] rd_addr = 32'd0;
  assign ext_mem0_ready = ext_mem0_ready_r && (rd_left == 8'd0);
  always @(posedge clk_sys) begin
    if (sdram_latency == 0) begin
      lat_cnt           <= 8'd0;
      ext_mem0_ready_r  <= 1'b1;
    end else if (ext_mem0_valid && ext_mem0_ready) begin
      lat_cnt           <= 8'd0;          // accepted: re-arm for the next one
      ext_mem0_ready_r  <= 1'b0;
    end else if (!ext_mem0_valid) begin
      lat_cnt           <= 8'd0;
      ext_mem0_ready_r  <= 1'b0;
    end else if (lat_cnt >= sdram_latency[7:0]) begin
      ext_mem0_ready_r  <= 1'b1;          // one accept cycle
    end else begin
      lat_cnt           <= lat_cnt + 8'd1;
      ext_mem0_ready_r  <= 1'b0;
    end
  end
  reg ext_mem0_resp_valid = 0;
  // +CARD_BACKEND is now INERT. It used to withhold the 128-bit line response this tier
  // supplied, because the built design has no line-response producer (z486_mister.sv used to
  // tie ext_mem0_line_resp_valid to 1'b0). The line port is gone from the design entirely, so
  // the tier and the card behave identically and the switch only keeps the documented command
  // line parsing.
  reg card_backend = 0;

  wire [7:0] debug_post_code;
  wire debug_post_write, debug_bios_loaded;
  wire [15:0] cpu_cs;
  wire cpu_pe;
  wire [31:0] cpu_eip, cpu_cs_base;
  // The guest RAM size this run boots, in pc9821_system.sv's code (log2 of the
  // MiB): 3'd5 = 32 MiB, the size the OSD defaults to and that these tiers and the
  // documentation assume. Overridable at runtime so the same pack can be booted at
  // another size without editing this file -- the quickest way to tell a size
  // mismatch from a real memory defect:
  //   TB_ARGS="+RAM_SIZE=0" bash tests/pc9821/run_userdisk.sh <image>   (1 MiB)
  // It behaves like an OSD selection made before the core started: the latch in
  // pc9821_system.sv samples the code until the pack has loaded.
  reg [2:0] ram_size = 3'd5;
  integer   ram_size_arg = 5;
  initial begin
    void'($value$plusargs("RAM_SIZE=%d", ram_size_arg));
    ram_size = ram_size_arg[2:0];
  end
  // The BIOS set the OSD selects: 0 = PC-9821Xe10 (the measured port-0xF0 strap,
  // this tier's default pack) and 1 = PC-9821Xe; 2..15 reserved (the Xe10 strap).
  // A runtime plusarg rather than an edit, so the SAME pack can be booted under either
  // set and the Xe path is reproducible:
  //   TB_ARGS="+BIOS_MODEL_XE" PC98_PACK=<xe pack> bash tests/pc9821/run_userdisk.sh <image>
  reg [3:0] bios_set = 4'd0;
  initial if ($test$plusargs("BIOS_MODEL_XE")) bios_set = 4'd1;
  // The OSD GDC Clock field: 0 = 2.5 MHz, the measured machine's port-0x31 strap (entry 0,
  // the config-less default, and what this tier boots unless asked otherwise), 1 = 5 MHz.
  // A runtime plusarg for the same reason as bios_set - the SAME pack boots under either
  // setting, so the firmware's own derivation of work-area 0000:054D bit 2 from the strap
  // is what changes, not the core's:
  //   TB_ARGS="+GDC_CLOCK_5MHZ" bash tests/pc9821/run_userdisk.sh <image>
  // The chain this exercises is the real one: BIOS.ROM@0xFD93C copies port 0x31 bit 7 into
  // 0x54D bit 5, and BIOS.ROM@0xF65AF-0xF65DF turns bit 5 into bit 2, which is the byte
  // TH01 builds the SCROLL im bit from (rec98/th01/hardware/scrollup.cpp:22-27) and TH03
  // refuses to run on (th03/op_01.cpp:836-847). This strap - and not the software-DIP/CG
  // record - is the setting.
  reg gdc_5mhz = 1'b0;
  initial if ($test$plusargs("GDC_CLOCK_5MHZ")) gdc_5mhz = 1'b1;
  // +FDD_FIXED: the FDD-mode switch at Fixed (0x00BE bit 2 = 1, the measured unit); default Auto.
  reg fdd_fixed = 1'b0;
  initial if ($test$plusargs("FDD_FIXED")) fdd_fixed = 1'b1;
  // +FDD_MODE=<n>: the OSD's Boot order list position (cfg_fdd_mode: 0 Auto, 1 640K, 2 1M, ...),
  // the 0xA3FF2 memory-switch nibble the BIOS boot helper reads (BANK7@0x5991).
  reg [2:0] fdd_mode = 3'd0;
  integer   fdd_mode_arg = 0;
  initial if ($value$plusargs("FDD_MODE=%d", fdd_mode_arg)) fdd_mode = fdd_mode_arg[2:0];
  // The strap as the FIRMWARE published it, sampled rather than read once, so a
  // measurement run cut short (+STOP_AT_CYCLE) still carries the answer: bit 5 is the
  // BIOS's direct copy of port 0x31 bit 7 (BIOS.ROM@0xFD93C) and bit 2 is what the games
  // read, derived from bit 5 by BIOS.ROM@0xF65AF-0xF65DF. The machine's own GDC test suite
  // recorded 0x50 on the Xe10 and 0x10 on this core (its RUNINFO.TXT),
  // i.e. bits 4, 5 and 2 agree and only bit 6 differs; this samples the two bits the
  // setting is about. Every 65,536 clk_sys is ~2 raster frames - far finer than any POST
  // transition, and cheap enough to run for the whole boot.
  reg [7:0] wa54d_last = 8'h00;
  reg       wa54d_b5_seen = 1'b0, wa54d_b2_seen = 1'b0;
  // 16 BITS, and that width IS the divider: this was an `integer` and `wa54d_div == 0`,
  // which wraps at 2^32 clk_sys (86 s of sim) rather than at the 65,536 the comment
  // above promises - so the sample never refreshed and all three registers stayed at
  // their power-up 0. Measured on the +GDC_CLOCK_5MHZ run of 2026-09-26: the LIVE byte
  // read 0x30 (bit 5 = 1) at cycle 100M while `wa54d_last` was still 0x00, and the
  // bit-5 assertion below failed blaming "the BIOS did not publish the port-0x31 strap"
  // when the BIOS had published it.
  reg [15:0] wa54d_div = 16'd0;
  always @(posedge clk_sys) begin
    wa54d_div <= wa54d_div + 1;
    if (wa54d_div == 0) begin
      wa54d_last   <= ram_byte(24'h00054D);
      if (ram_byte(24'h00054D)[5]) wa54d_b5_seen <= 1'b1;
      if (ram_byte(24'h00054D)[2]) wa54d_b2_seen <= 1'b1;
    end
  end
  wire [7:0] video_r, video_g, video_b;
  wire video_ce, video_blank_n, video_hsync, video_vsync;

  // ---- the ITF's configuration-record check, measured per boot ------------------
  // The check reads the CG window and compares with AA55, and the repair that writes the
  // record runs AFTER it -- so a cold store cannot pass. +RESET_AFTER_REPAIR pulses the
  // guest reset once the repair has landed, and this records what the check read on each
  // pass, so "does the second boot pass?" is answered rather than argued. Off by default:
  // an acceptance run must not change.
  reg        guest_reset = 1'b0;
  reg        rr_armed = 1'b0, did_reset = 1'b0;
  reg [31:0] rr_count = 32'd0;
  reg [7:0]  chk_read [0:7];
  reg [7:0]  pass1_read [0:3];
  reg [2:0]  chk_n = 3'd0;
  // Observe the byte where the responder CONSUMES it, after synchronous RAM/glyph
  // waits. cg_win_rd is only the request; backing RAM is NOT the CPU's answer when
  // the config seed/echo mux intervenes. The responder holds address/byte_index
  // through S_READ_CAPTURE, so metadata and read_lane name the same returned byte.
  wire cg_capture = !reset && !guest_reset && dut.memory.u_window.route_cg &&
                    (dut.memory.u_window.state == dut.memory.u_window.S_READ_CAPTURE);
  wire cg_bus_read = cg_capture && (dut.memory.u_window.line_request ||
                    dut.memory.u_window.write_be[dut.memory.u_window.byte_index[1:0]]);
  wire [13:0] cg_bus_offset = dut.memory.u_window.indexed_addr;
  wire [12:0] cg_bus_store = dut.u_cg.cg_rd_addr;
  // Opt-in negative control reproduces the OLD instrument's wrong source. It must
  // fail the assembled-response assertion below, not silently publish plausible data.
  wire [7:0] cg_bus_byte = $test$plusargs("CG_TRACE_OLD_SOURCE")
                        ? dut.u_cg.u_cg_ram.ram[cg_bus_store]
                        : dut.memory.u_window.read_lane;
  wire io_read_capture = !dut.iobus.request_write &&
      (((dut.iobus.state == dut.iobus.S_BYTE) &&
        !(dut.iobus.device_port && dut.iobus.device_rd_wait && !dut.iobus.flush_required)) ||
       ((dut.iobus.state == dut.iobus.S_DEVWAIT) && !dut.iobus.device_rd_hold));
  wire io_a9_read = !reset && !guest_reset && io_read_capture &&
                   (dut.iobus.port_addr == 16'h00A9);
  wire cfg_bus_read = (cg_bus_read && cg_bus_offset[0]) || io_a9_read;
  wire [12:0] cfg_bus_store = io_a9_read ? dut.u_cg.cg_ram_addr : cg_bus_store;
  wire [7:0] cfg_bus_byte = io_a9_read ? dut.iobus.lane_rdata : cg_bus_byte;
  reg [111:0] cg_record_observed = 112'd0;
  reg [13:0] cg_record_seen = 14'd0;
  reg [15:0] cg_config_observed = 16'd0;
  reg [1:0] cg_config_seen = 2'd0;
  reg [191:0] sdip_observed = 192'd0;
  reg [23:0] sdip_seen = 24'd0;
  reg [7:0] port31_observed = 8'd0;
  reg port31_seen = 1'b0;
  always @(posedge clk_sys) begin
    if (reset || guest_reset || dut.cpu_reset_req) begin
      sdip_seen <= 24'd0;
      port31_seen <= 1'b0;
    end else if (io_read_capture) begin
      if (dut.iobus.sdip_data_port) begin
        sdip_observed[32'(dut.iobus.sdip_bank_index)*8 +: 8] <= dut.iobus.lane_rdata;
        sdip_seen[dut.iobus.sdip_bank_index] <= 1'b1;
      end
      if (dut.iobus.port_addr == 16'h0031) begin
        port31_observed <= dut.iobus.lane_rdata;
        port31_seen <= 1'b1;
      end
    end
  end
  reg [127:0] cg_trace_assembled = 128'd0;
  reg [15:0] cg_trace_lanes = 16'd0;
  reg cg_trace_active = 1'b0;
  // Read-only instrument: no signal drives the device. Reset discards observations
  // from the old boot, never synthesises values for cells the guest has not read.
  always @(posedge clk_sys) begin
    if (reset || guest_reset || dut.cpu_reset_req) begin
      cg_record_seen <= 14'd0;
      cg_config_seen <= 2'd0;
    end else if (cfg_bus_read) begin
      if (io_a9_read && cg_bus_read)
        $fatal(1, "CG TRACE: overlapping I/O and window response owners");
      if (cfg_bus_store >= 13'h810 && cfg_bus_store < 13'h81E) begin
        cg_record_observed[(32'(cfg_bus_store) - 32'h810)*8 +: 8] <= cfg_bus_byte;
        cg_record_seen[cfg_bus_store - 13'h810] <= 1'b1;
      end
      if (cfg_bus_store == 13'h400 || cfg_bus_store == 13'h401) begin
        cg_config_observed[{cfg_bus_store[0], 3'b000} +: 8] <= cfg_bus_byte;
        cg_config_seen[cfg_bus_store[0]] <= 1'b1;
      end
    end
    // This assertion calibrates the observer against the FINAL responder word/line.
    // Every lane is sampled, including dummy even offsets, not just the CPU byte mask.
    if (reset || guest_reset) begin
      cg_trace_active <= 1'b0;
      cg_trace_assembled <= 128'd0;
      cg_trace_lanes <= 16'd0;
    end else begin
      if (dut.memory.u_window.state == dut.memory.u_window.S_IDLE &&
          dut.memory.u_window.cpu_valid && dut.memory.u_window.route_cg &&
          !dut.memory.u_window.cpu_write) begin
        cg_trace_active <= 1'b1;
        cg_trace_assembled <= 128'd0;
        cg_trace_lanes <= 16'd0;
      end
      if (cg_capture) begin
        cg_trace_assembled[32'(dut.memory.u_window.byte_index)*8 +: 8] <= cg_bus_byte;
        cg_trace_lanes[dut.memory.u_window.byte_index] <= 1'b1;
      end
      if (cg_trace_active && dut.memory.win_cpu_resp_valid) begin
        if (cg_trace_lanes[3:0] != 4'hF ||
            cg_trace_assembled[31:0] !== dut.memory.win_cpu_dout)
          $fatal(1, "CG TRACE: sampled bytes differ from CPU word response (sample=%08x bus=%08x)",
                 cg_trace_assembled[31:0], dut.memory.win_cpu_dout);
        cg_trace_active <= 1'b0;
      end else if (cg_trace_active && dut.memory.win_cpu_line_word_valid) begin
        if (cg_trace_lanes != 16'hFFFF ||
            cg_trace_assembled !== dut.memory.win_cpu_line_word)
          $fatal(1, "CG TRACE: sampled bytes differ from CPU line response");
        cg_trace_active <= 1'b0;
      end
    end
  end
  wire repair_marker_write = dut.u_cg.cg_wr_win &&
                             dut.u_cg.cg_wr_addr == 13'h818 &&
                             dut.u_cg.cg_wr_data == 8'hAA;

  always @(posedge clk_sys) begin
    // Record enabled odd-offset RESPONSE bytes, not requests or backing storage.
    if (cg_bus_read && cg_bus_offset[0] &&
        pc_now >= 32'h000F_C670 && pc_now <= 32'h000F_C6B6 && chk_n < 3'd7) begin
      chk_read[chk_n] <= cg_bus_byte;
      chk_n <= chk_n + 3'd1;
    end
    if ($test$plusargs("RESET_AFTER_REPAIR") && !did_reset) begin
      if (repair_marker_write) rr_armed <= 1'b1;
      if (rr_armed) begin
        rr_count <= rr_count + 32'd1;
        if (rr_count == 32'd2000) guest_reset <= 1'b1;   // let the record land
        if (rr_count == 32'd2032) begin
          guest_reset <= 1'b0;
          did_reset <= 1'b1;
          pass1_read[0] <= chk_read[0];
          pass1_read[1] <= chk_read[1];
          pass1_read[2] <= chk_read[2];
          pass1_read[3] <= chk_read[3];
          chk_n <= 3'd0;
        end
      end
    end
  end

  // The whole 1 MiB pack: the layout is verified against the dumps by
  // tools/check_pack.py before the run, so the loads below are exact and the
  // byte ranges they cover are the ones the pack describes. The array must reach
  // the pack's highest word -- the PC-9801-86 SOUND.ROM window at +0xC6800, whose
  // last word is 0x653FF -- because $readmemh loads the whole mirror (which
  // grew with the 16 KiB sound region; it ends above the font at
  // +0x80000, whose last word is 0x633FF).
  reg [15:0] pack_words [0:19'h653ff];
  reg [15:0] disk_words [0:IMG_WORDS-1];
  // Guest RAM plus the 1 MiB firmware reserve above it (pack_base ==
  // guest_ram_bytes). The pack lives in this SDRAM in hardware, so the model has
  // to store it; otherwise the reset vector reads open bus. The bound below is
  // the reserve's own end and so it moved with the reserve (it was 0x0208_0000
  // for 512 KiB); the GVRAM above it is unmodelled UNLESS +SDRAM_FULL=1, which
  // is the switch that makes the graphics datapath read and write real storage
  // here instead of constant all-ones. The array is sized for that switch: 34 MiB
  // covers guest RAM + pack + GVRAM at every size this bench runs.
  reg [31:0] ram [0:8912895];
  integer idx, lane;

  // THE GLYPH PORT (hps SDRAM port 1, pc9821_memory_subsystem's fmem): the JIS reads of port
  // 0xA9 / the CG window and the text scanout's row-cache walker fetch 8-dword bursts of the
  // pack's FONT.ROM copy here. It was left unconnected (ready 0), so the first JIS glyph a
  // guest read through port 0xA9 held the I/O bus for ever. Served from the same SDRAM model
  // the pack lives in: accept when idle, then one dword per cycle.
  wire [31:0] ext_mem1_addr, ext_mem1_din;
  wire [3:0]  ext_mem1_be;
  wire [7:0]  ext_mem1_burstcount;
  wire        ext_mem1_valid, ext_mem1_write;
  reg  [31:0] ext_mem1_dout = 32'd0;
  reg         ext_mem1_resp_valid = 1'b0;
  reg  [7:0]  f1_left = 8'd0;
  reg  [31:0] f1_addr = 32'd0;
  wire        ext_mem1_ready = (f1_left == 8'd0);
  always @(posedge clk_sys) begin
    ext_mem1_resp_valid <= 1'b0;
    if (f1_left != 8'd0) begin
      ext_mem1_dout <= ram[f1_addr[31:2]];
      ext_mem1_resp_valid <= 1'b1;
      f1_addr <= f1_addr + 32'd4;
      f1_left <= f1_left - 8'd1;
    end else if (ext_mem1_valid && !ext_mem1_write) begin
      f1_addr <= ext_mem1_addr;
      f1_left <= (ext_mem1_burstcount == 8'd0) ? 8'd1 : ext_mem1_burstcount;
    end
  end

  // WHICH I/O-LATENCY PROFILE this tier builds. The bench default is the min table
  // (IO_LATENCY_PROFILE 0, the same one the card runs); `-DIO_FAITHFUL` selects 2, the
  // machine's own measured access TIMES (docs/probes/IO.TXT), which is the compile-time
  // devkit switch.
  // One source, one variable, so a boot A/B is one build per side and the delta is
  // attributable. The faithful table prices 0x005F by direction (826 ns read / IO.TXT's
  // 1621 ns write), while the min profile charges its ONE value, 1621 ns, in both directions
  // (a wr-dependent value there trips a Quartus fitter bug); that port is what the BIOS's own
  // delay loops are calibrated on.
  // The CD-DA ring (src/soc/cdda.v), as occupancy only: the player's stereo samples go in on
  // cdda_wr and drain at 44.1 kHz (one per 50 MHz / 44100 = 1134 clk_sys); CDDA_REQ is up while
  // a sector fits in its 6144 samples (CDDA_REQ4 while four do), CDDA_PLAYED pulses per 588
  // samples drained, and the player's flush empties it. So a PLAY AUDIO takes its real length
  // here and the READ SUB-CHANNEL status moves 0x11 -> 0x13 when it would on the core.
  wire cdda_wr;
  wire cdda_flush;
  reg  [12:0] cdda_fill = 13'd0;
  reg  [10:0] cdda_div = 11'd0;
  reg  [9:0]  cdda_pn = 10'd0;
  reg         cdda_played = 1'b0;
  wire cdda_req  = TB_CDROM && cdda_fill <= 13'd5548;   // 6144 - 588 - 8
  wire cdda_req4 = TB_CDROM && cdda_fill <= 13'd3784;   // 6144 - 2352 - 8
  wire cdda_drain = (cdda_div == 11'd1133 && cdda_fill != 13'd0);
  always @(posedge clk_sys) begin
    cdda_div <= (cdda_div == 11'd1133) ? 11'd0 : cdda_div + 11'd1;
    cdda_played <= 1'b0;
    if (cdda_flush) begin
      cdda_fill <= 13'd0; cdda_pn <= 10'd0;
    end else begin
      cdda_fill <= cdda_fill + (cdda_wr ? 13'd1 : 13'd0) - (cdda_drain ? 13'd1 : 13'd0);
      if (cdda_drain) begin
        if (cdda_pn == 10'd587) begin cdda_pn <= 10'd0; cdda_played <= 1'b1; end
        else cdda_pn <= cdda_pn + 10'd1;
      end
    end
  end

`ifdef IO_FAITHFUL
  localparam [1:0] TB_IO_PROFILE = 2'd2;
`else
  localparam [1:0] TB_IO_PROFILE = 2'd0;
`endif

  // USERDISK_SYSFREQ / USERDISK_CACHE_BITS (run_userdisk.sh): build the tier at the card's
  // clk_sys and cache geometry, so a guest whose behaviour depends on the CPU-to-device rate
  // ratio can be run as the 90 MHz card runs it (z486_mister.sv: CLOCK_RATE_HZ, *_SET_BITS).
`ifdef TB_SYS_FREQ
  localparam integer TB_FREQ = `TB_SYS_FREQ;
`else
  localparam integer TB_FREQ = 50_000_000;
`endif
`ifdef TB_CACHE_BITS
  localparam integer TB_CBITS = `TB_CACHE_BITS;
`else
  localparam integer TB_CBITS = 4;
`endif

  pc9821_system #(
      .SYS_FREQ(TB_FREQ), .DCACHE_SET_BITS(TB_CBITS), .ICACHE_SET_BITS(TB_CBITS),
      .ENABLE_X87(1'b0), .IO_LATENCY_PROFILE(TB_IO_PROFILE),
      .CDROM_EN(TB_CDROM), .CDROM_AUDIO_EN(TB_CDROM), .CDROM_LOG_EN(TB_CDROM),
      .SDRAM_PHASE_DYN(TB_SDPH)
  // ==== DUT ====
  ) dut (
      // Video runs on the dot clock; the bench drives it at clk_sys with
      // The dot rate is an enable on clk_sys inside the system, so
      // there is no separate video clock to drive here.
      .clk_sys(clk_sys),
      .reset(reset | guest_reset), .hps_apply_reset(hps_apply_reset),
      .rtc(rtc),
      .ext_mem_busy(1'b0),
      .ext_mem0_addr(ext_mem0_addr), .ext_mem0_din(ext_mem0_din),
      .ext_mem0_dout(ext_mem0_dout),
      .ext_mem0_resp_valid(ext_mem0_resp_valid),
      .ext_mem0_be(ext_mem0_be), .ext_mem0_burstcount(ext_mem0_burstcount),
      .ext_mem0_ready(ext_mem0_ready),
      .ext_mem0_valid(ext_mem0_valid), .ext_mem0_write(ext_mem0_write),
      .ext_mem1_addr(ext_mem1_addr), .ext_mem1_din(ext_mem1_din), .ext_mem1_dout(ext_mem1_dout),
      .ext_mem1_resp_valid(ext_mem1_resp_valid), .ext_mem1_be(ext_mem1_be),
      .ext_mem1_burstcount(ext_mem1_burstcount), .ext_mem1_ready(ext_mem1_ready),
      .ext_mem1_valid(ext_mem1_valid), .ext_mem1_write(ext_mem1_write),
      .ext_mem2_addr(ext_mem2_addr), .ext_mem2_din(ext_mem2_din), .ext_mem2_dout(ext_mem2_dout),
      .ext_mem2_resp_valid(ext_mem2_resp_valid), .ext_mem2_be(ext_mem2_be),
      .ext_mem2_burstcount(ext_mem2_burstcount), .ext_mem2_ready(1'b1),
      .ext_mem2_valid(ext_mem2_valid), .ext_mem2_write(ext_mem2_write),
      .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
      .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
      .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
      .img_mounted(img_mounted), .img_readonly(img_readonly),
      .img_size(img_size), .img_lba(img_lba), .img_blk_cnt(img_blk_cnt),
      .img_rd(img_rd), .img_wr(img_wr), .img_ack(img_ack),
      .img_buff_addr(img_buff_addr), .img_buff_din(img_buff_din),
      .img_buff_dout(img_buff_dout), .img_buff_wr(img_buff_wr),
      .fdd_mounted(fdd_mounted), .fdd_size(img_size), .fdd_lba(fdd_lba),
      .fdd_blk_cnt(fdd_blk_cnt), .fdd_rd(fdd_rd), .fdd_wr(fdd_wr), .fdd_ack(fdd_ack),
      .fdd_buff_din(fdd_buff_din),
      .fdd1_mounted(fdd1_mounted), .fdd1_size(fdd1_size), .fdd1_lba(fdd1_lba),
      .fdd1_blk_cnt(fdd1_blk_cnt), .fdd1_rd(fdd1_rd), .fdd1_wr(fdd1_wr), .fdd1_ack(fdd1_ack),
      .fdd1_buff_din(fdd1_buff_din),
      .cd_mounted(hdd1_mounted), .cd_size(hdd1_size), .cd_lba(hdd1_lba),
      .cd_blk_cnt(hdd1_blk_cnt), .cd_rd(hdd1_rd), .cd_ack(hdd1_ack),
      .cdda_req(cdda_req), .cdda_req4(cdda_req4), .cdda_played(cdda_played),
      .cdda_flush(cdda_flush), .cdda_wr(cdda_wr), .cdda_data(),
      // 32 MiB guest RAM: pc9821_system's size code is log2(MiB), so 3'd5 is the
      // size the documentation describes and the screen's memory line is measured at.
      // This bench models a module whose CEILING is that same 32 MiB, so the pack is
      // placed at pack_base == 32 MiB exactly as before the size/pack split
      // and the bench's SDRAM content model below needs no change.
      .ps2_key(ps2_key), .ps2_mouse(ps2_mouse), .ram_size(ram_size),
      .ram_size_max(ram_size),
      // The OSD's BIOS set: +BIOS_MODEL_XE selects the PC-9821Xe strap.
      .bios_set(bios_set),
      // The OSD's GDC Clock field: +GDC_CLOCK_5MHZ selects 0x73 (port 0x31 bit 7 clear).
      .gdc_clock_5m(gdc_5mhz), .fdd_dip_fixed(fdd_fixed),
      .cfg_fdd_mode(fdd_mode),
      // 5 MHz: this bench mounts disks into the real firmware and so must not change the
      // display's GDC line step. The strap decode and the step have their own benches.
      .bios_setup(1'b0),
      // The debug UART FIFO and its accept handshake live in the top level (z486_mister.sv),
      // which this tier does not build - and nothing here reads dbg_uart_byte either. Tying
      // accept high lets the report emitter free-run at one byte per clk_sys (the design leaves
      // the emitted byte stream unchanged when the FIFO always has room).
      .dbg_uart_accept(1'b1), .sdph_step_req(sdph_req), .sdph_step_up(sdph_up),
      .sdph_step_ack(sdph_ack), .sdph_fault(sdph_fault),
      .trace_trig(),
      .debug_post_code(debug_post_code), .debug_post_write(debug_post_write),
      .debug_bios_loaded(debug_bios_loaded), .cpu_cs(cpu_cs),
      .cpu_pe(cpu_pe), .cpu_eip(cpu_eip), .cpu_cs_base(cpu_cs_base),
      .video_ce(video_ce), .video_blank_n(video_blank_n),
      .video_hsync(video_hsync), .video_vsync(video_vsync),
      .video_r(video_r), .video_g(video_g), .video_b(video_b)
  );

  always @(posedge clk_sys) begin
    ext_mem0_resp_valid <= 1'b0;
    if (ext_mem0_valid && ext_mem0_ready) begin
      idx = ext_mem0_addr[25:2];
      if (ext_mem0_write) begin
        if (ext_mem0_addr < sdram_top)
          for (lane = 0; lane < 4; lane = lane + 1)
            if (ext_mem0_be[lane])
              ram[idx][lane*8 +: 8] <= ext_mem0_din[lane*8 +: 8];
      end else begin
        // The first beat of a word-counted read burst; the rest follow one per cycle.
        ext_mem0_dout <= (ext_mem0_addr < sdram_top) ? ram[idx] :
                                                        32'hFFFF_FFFF;
        ext_mem0_resp_valid <= 1'b1;
        rd_addr <= ext_mem0_addr + 32'd4;
        rd_left <= (ext_mem0_burstcount == 8'd0) ? 8'd0 : (ext_mem0_burstcount - 8'd1);
      end
    end else if (rd_left != 8'd0) begin
      idx = rd_addr[25:2];
      ext_mem0_dout <= (rd_addr < sdram_top) ? ram[idx] : 32'hFFFF_FFFF;
      ext_mem0_resp_valid <= 1'b1;
      rd_addr <= rd_addr + 32'd4;
      rd_left <= rd_left - 8'd1;
    end
  end
  // ==== STIMULUS ====

  task automatic send_word(input [26:0] addr, input [15:0] data);
    begin
      while (ioctl_wait) @(negedge clk_sys);
      ioctl_addr = addr;
      ioctl_dout = data;
      ioctl_wr = 1;
      @(negedge clk_sys);
      ioctl_wr = 0;
    end
  endtask

  reg [2:0] disk_state = 0;
  reg [15:0] disk_index = 0;
  reg [15:0] disk_total = 0;   // words in this handshake: (img_blk_cnt+1) * 256
  // +IMG_FILE=<path>: serve every sector straight from the image file instead of the
  // preloaded disk_words array, so an image larger than a Verilator array can hold (a
  // 542 MB disk is 284M words; Verilator refuses a vector over 2^30 bits) runs
  // whole. disk_words still holds the first SECTORS for the IPL-data check. One
  // session (up to 64 blocks) is read into file_buf when the request arrives.
  integer    img_fd = 0;
  reg [15:0] file_buf [0:16383];
  initial begin : img_file_open
    reg [1023:0] img_path;
    if ($value$plusargs("IMG_FILE=%s", img_path)) begin
      img_fd = $fopen(img_path, "rb");
      if (img_fd == 0) $fatal(1, "TB_PC9821_USERDISK: FAIL (+IMG_FILE could not be opened)");
      $display("IMG_FILE serving sectors from the image file (fd %0d)", img_fd);
    end
    // +IMG_RW: mount the disk writable. The file is never written: each sector the guest
    // writes lands in img_ovl (word-addressed, lba*256+word) and every later read of it is
    // served from there. Without this the drive is read-only and the guest's first WRITE
    // SECTORS aborts, which the IDE BIOS answers with an endless RECALIBRATE/retry loop -
    // a real disk does that under VEM486+HSB, while the MiSTer mounts it writable.
    if ($test$plusargs("IMG_RW")) begin
      if (img_fd == 0) $fatal(1, "TB_PC9821_USERDISK: FAIL (+IMG_RW needs +IMG_FILE)");
      img_readonly = 1'b0;
      $display("IMG_RW the disk is writable; writes go to an in-memory overlay");
    end
  end
  reg [15:0] img_ovl [longint];
  integer    img_wr_log = 0;
  integer    img1_fd = 0;
  reg        srv1 = 0;          // the session in flight is slot 3's
  reg [15:0] img1_ovl [longint];
  initial begin : img1_file_open
    reg [1023:0] img1_path;
    if ($value$plusargs("IMG1_FILE=%s", img1_path))
      $fatal(1, "TB_PC9821_USERDISK: FAIL (+IMG1_FILE: the second hard disk was removed)");
    if ($value$plusargs("CD_FILE=%s", img1_path)) begin
      if (!TB_CDROM) $fatal(1, "TB_PC9821_USERDISK: FAIL (+CD_FILE needs a -DUSERDISK_CD build)");
      img1_fd = $fopen(img1_path, "rb");
      if (img1_fd == 0) $fatal(1, "TB_PC9821_USERDISK: FAIL (+CD_FILE could not be opened)");
      $display("CD_FILE slot 4 (the CD-ROM) served from the image file (fd %0d)", img1_fd);
    end
  end
  task automatic img1_file_read(input [31:0] lba, input [15:0] words);
    integer w, lo, hi;
    begin
      void'($fseek(img1_fd, lba * 512, 0));
      for (w = 0; w < words; w = w + 1) begin
        lo = $fgetc(img1_fd); hi = $fgetc(img1_fd);
        file_buf[w] = (lo < 0 || hi < 0) ? 16'd0 : {hi[7:0], lo[7:0]};
        if (img1_ovl.exists(longint'(lba) * 256 + w)) file_buf[w] = img1_ovl[longint'(lba) * 256 + w];
      end
    end
  endtask
  integer hdd1_rd_log = 0;
  integer    fdd_fd = 0;
  reg        srvf = 0;          // the session in flight is slot 1's (FDD1)
  reg [15:0] fdd_ovl [longint];
  integer    fdd_rd_log = 0;
  initial begin : fdd_file_open
    reg [1023:0] fdd_path;
    if ($value$plusargs("FDD_FILE=%s", fdd_path)) begin
      fdd_fd = $fopen(fdd_path, "rb");
      if (fdd_fd == 0) $fatal(1, "TB_PC9821_USERDISK: FAIL (+FDD_FILE could not be opened)");
      $display("FDD_FILE slot 1 (FDD1) served from the image file (fd %0d)", fdd_fd);
    end
  end
  integer    fdd2_fd = 0;
  reg        srvf2 = 0;         // the session in flight is the fdd1 slot's (FDD2)
  reg [15:0] fdd2_ovl [longint];
  initial begin : fdd2_file_open
    reg [1023:0] fdd2_path;
    if ($value$plusargs("FDD2_FILE=%s", fdd2_path)) begin
      fdd2_fd = $fopen(fdd2_path, "rb");
      if (fdd2_fd == 0) $fatal(1, "TB_PC9821_USERDISK: FAIL (+FDD2_FILE could not be opened)");
      $display("FDD2_FILE (FDD2) served from the image file (fd %0d)", fdd2_fd);
    end
  end
  task automatic fdd2_file_read(input [31:0] lba, input [15:0] words);
    integer w, lo, hi;
    begin
      void'($fseek(fdd2_fd, lba * 512, 0));
      for (w = 0; w < words; w = w + 1) begin
        lo = $fgetc(fdd2_fd); hi = $fgetc(fdd2_fd);
        file_buf[w] = (lo < 0 || hi < 0) ? 16'd0 : {hi[7:0], lo[7:0]};
        if (fdd2_ovl.exists(longint'(lba) * 256 + w)) file_buf[w] = fdd2_ovl[longint'(lba) * 256 + w];
      end
    end
  endtask
  task automatic fdd_file_read(input [31:0] lba, input [15:0] words);
    integer w, lo, hi;
    begin
      void'($fseek(fdd_fd, lba * 512, 0));
      for (w = 0; w < words; w = w + 1) begin
        lo = $fgetc(fdd_fd); hi = $fgetc(fdd_fd);
        file_buf[w] = (lo < 0 || hi < 0) ? 16'd0 : {hi[7:0], lo[7:0]};
        if (fdd_ovl.exists(longint'(lba) * 256 + w)) file_buf[w] = fdd_ovl[longint'(lba) * 256 + w];
      end
    end
  endtask
  task automatic img_file_read(input [31:0] lba, input [15:0] words);
    integer w, lo, hi;
    begin
      void'($fseek(img_fd, lba * 512, 0));
      for (w = 0; w < words; w = w + 1) begin
        lo = $fgetc(img_fd); hi = $fgetc(img_fd);
        file_buf[w] = (lo < 0 || hi < 0) ? 16'd0 : {hi[7:0], lo[7:0]};
        if (img_ovl.exists(longint'(lba) * 256 + w)) file_buf[w] = img_ovl[longint'(lba) * 256 + w];
      end
    end
  endtask
  // +HPS_DELAY=<n> / +HPS_GAP=<g>: the host's latency, which this model otherwise leaves out (its
  // ack is the next cycle and its words back to back). The MiSTer's hps_io acks a request only
  // when the ARM services it and then delivers one word per SPI strobe; n cycles before the ack
  // and g idle cycles between words stand in for that, for both slots and both floppy files.
  int unsigned hps_delay = 0, hps_gap = 0;
  int unsigned hps_wait = 0, hps_gapc = 0;
  initial begin
    void'($value$plusargs("HPS_DELAY=%d", hps_delay));
    void'($value$plusargs("HPS_GAP=%d", hps_gap));
  end
  always @(posedge clk_sys) begin
    img_buff_wr <= 1'b0;
    case (disk_state)
      0: if ((hdd1_rd || hdd1_wr || img_rd || img_wr || (fdd_rd && fdd_fd != 0) ||
             (fdd1_rd && fdd2_fd != 0)) && hps_wait < hps_delay) begin
        hps_wait <= hps_wait + 1;
      end else if (fdd_rd && fdd_fd != 0) begin
        hps_wait <= 0;
        srv1 <= 1'b0; srvf <= 1'b1; srvf2 <= 1'b0;
        fdd_ack <= 1'b1;
        disk_index <= 0;
        fdd_file_read(fdd_lba, ({10'd0, fdd_blk_cnt} + 16'd1) << 8);
        disk_total <= ({10'd0, fdd_blk_cnt} + 16'd1) << 8;
        if (fdd_rd_log < 400)
          $display("FDD READ lba=%0d blocks=%0d cyc=%0d", fdd_lba, fdd_blk_cnt + 1, tb_cycle);
        fdd_rd_log = fdd_rd_log + 1;
        disk_state <= 1;
      end else if (fdd1_rd && fdd2_fd != 0) begin
        hps_wait <= 0;
        srv1 <= 1'b0; srvf <= 1'b0; srvf2 <= 1'b1;
        fdd1_ack <= 1'b1;
        disk_index <= 0;
        fdd2_file_read(fdd1_lba, ({10'd0, fdd1_blk_cnt} + 16'd1) << 8);
        disk_total <= ({10'd0, fdd1_blk_cnt} + 16'd1) << 8;
        if (fdd_rd_log < 400)
          $display("FDD2 READ lba=%0d blocks=%0d cyc=%0d", fdd1_lba, fdd1_blk_cnt + 1, tb_cycle);
        fdd_rd_log = fdd_rd_log + 1;
        disk_state <= 1;
      end else if (fdd1_wr && fdd2_fd != 0) begin
        hps_wait <= 0;
        srv1 <= 1'b0; srvf <= 1'b0; srvf2 <= 1'b1;
        fdd1_ack <= 1'b1;
        disk_index <= 0;
        img_buff_addr <= 13'd0;
        disk_total <= ({10'd0, fdd1_blk_cnt} + 16'd1) << 8;
        $display("FDD2 WRITE lba=%0d blocks=%0d cyc=%0d", fdd1_lba, fdd1_blk_cnt + 1, tb_cycle);
        disk_state <= 3;
      end else if (fdd_wr && fdd_fd != 0) begin
        hps_wait <= 0;
        srv1 <= 1'b0; srvf <= 1'b1; srvf2 <= 1'b0;
        fdd_ack <= 1'b1;
        disk_index <= 0;
        img_buff_addr <= 13'd0;
        disk_total <= ({10'd0, fdd_blk_cnt} + 16'd1) << 8;
        $display("FDD WRITE lba=%0d blocks=%0d cyc=%0d", fdd_lba, fdd_blk_cnt + 1, tb_cycle);
        disk_state <= 3;
      end else if (hdd1_rd && img1_fd != 0) begin
        hps_wait <= 0;
        // Slot 3: the same read session, from the second file.
        srv1 <= 1'b1; srvf <= 1'b0; srvf2 <= 1'b0;
        hdd1_ack <= 1'b1;
        disk_index <= 0;
        img1_file_read(hdd1_lba, ({10'd0, hdd1_blk_cnt} + 16'd1) << 8);
        disk_total <= ({10'd0, hdd1_blk_cnt} + 16'd1) << 8;
        if (hdd1_rd_log < 40)
          $display("CD READ lba=%0d blocks=%0d cyc=%0d", hdd1_lba, hdd1_blk_cnt + 1, tb_cycle);
        hdd1_rd_log = hdd1_rd_log + 1;
        disk_state <= 1;
      end else if (hdd1_wr && img1_fd != 0) begin
        hps_wait <= 0;
        srv1 <= 1'b1;
        hdd1_ack <= 1'b1;
        disk_index <= 0;
        img_buff_addr <= 13'd0;
        disk_total <= 16'd256;
        $display("HDD1 WRITE lba=%0d cyc=%0d", hdd1_lba, tb_cycle);
        disk_state <= 3;
      end else if (img_rd) begin
        hps_wait <= 0;
        srv1 <= 1'b0; srvf <= 1'b0; srvf2 <= 1'b0;
        img_ack <= 1'b1;
        disk_index <= 0;
        if (img_fd != 0) img_file_read(img_lba, ({10'd0, img_blk_cnt} + 16'd1) << 8);
        // hps_io's sd_blk_cnt protocol: one ack session carries (img_blk_cnt+1) blocks
        // of 256 words over one sd_buff_addr window. pc9821_block_io asks for more than
        // one block only for a run of sequential reads (its read-ahead window); a write
        // or a random read is the single block this model always streamed.
        disk_total <= ({10'd0, img_blk_cnt} + 16'd1) << 8;
        disk_state <= 1;
      end else if (img_wr && !img_readonly) begin
        hps_wait <= 0;
        srv1 <= 1'b0; srvf <= 1'b0; srvf2 <= 1'b0;
        // Write session: the host reads the drive's sector buffer, presenting the
        // address and sampling img_buff_dout. The buffer read is registered, so each
        // address is held two cycles (states 3, 4) before the word is taken (state 5).
        img_ack <= 1'b1;
        disk_index <= 0;
        img_buff_addr <= 13'd0;
        disk_total <= ({10'd0, img_blk_cnt} + 16'd1) << 8;
        if (img_wr_log < 200)
          $display("IMG WRITE lba=%0d blocks=%0d cyc=%0d", img_lba, img_blk_cnt + 1, tb_cycle);
        img_wr_log = img_wr_log + 1;
        disk_state <= 3;
      end
      3: disk_state <= 4;
      4: disk_state <= 5;
      5: begin
        if (srvf) fdd_ovl[longint'(fdd_lba) * 256 + disk_index] = fdd_buff_din;
        else if (srvf2) fdd2_ovl[longint'(fdd1_lba) * 256 + disk_index] = fdd1_buff_din;
        else if (srv1) img1_ovl[longint'(hdd1_lba) * 256 + disk_index] = hdd1_buff_din;
        else      img_ovl[longint'(img_lba) * 256 + disk_index] = img_buff_dout;
        if (disk_index == (disk_total - 16'd1)) disk_state <= 2;
        else begin
          disk_index <= disk_index + 16'd1;
          img_buff_addr <= disk_index[12:0] + 13'd1;
          disk_state <= 3;
        end
      end
      1: if (hps_gapc < hps_gap) hps_gapc <= hps_gapc + 1;
      else begin
        hps_gapc <= 0;
        img_buff_wr <= 1'b1;
        img_buff_addr <= disk_index[12:0];
        img_buff_din <= (img_fd != 0 || srv1 || srvf || srvf2) ? file_buf[disk_index[13:0]] :
            (img_lba*32'd256 + {16'd0, disk_index}) < IMG_WORDS ?
            disk_words[img_lba*32'd256 + {16'd0, disk_index}] : 16'd0;
        if (disk_index == (disk_total - 16'd1)) disk_state <= 2;
        else disk_index <= disk_index + 16'd1;
      end
      2: begin
        img_ack <= 1'b0;
        hdd1_ack <= 1'b0;
        fdd_ack <= 1'b0;
        fdd1_ack <= 1'b0;
        disk_state <= 0;
      end
      default: disk_state <= 0;
    endcase
  end

  wire [31:0] pc_now = cpu_cs_base + cpu_eip;
  // +FDCIRQ_AFTER=<cycle>: every change of the FDC's interrupt level or its pending-drive set
  // after that cycle (the first 400), with the controller state - for an IRQ11 the guest did
  // not ask for.
  longint fdcirq_after = 0; integer fdcirq_cnt = 0;
  reg fdcirq_q = 1'b0; reg [3:0] fdcpend_q = 4'd0;
  initial void'($value$plusargs("FDCIRQ_AFTER=%d", fdcirq_after));
  always @(posedge clk_sys) begin
    fdcirq_q <= dut.iobus.fdc.irq; fdcpend_q <= dut.iobus.fdc.pend;
    if (fdcirq_after != 0 && tb_cycle >= fdcirq_after && fdcirq_cnt < 400 &&
        (dut.iobus.fdc.irq != fdcirq_q || dut.iobus.fdc.pend != fdcpend_q)) begin
      fdcirq_cnt <= fdcirq_cnt + 1;
      $display("FDCIRQ irq=%0d pend=%b st=%0d res_irq=%0d armed=%b%b ins_dly=%0d/%0d pc=%08x cyc=%0d",
               dut.iobus.fdc.irq, dut.iobus.fdc.pend, dut.iobus.fdc.st, dut.iobus.fdc.res_irq,
               dut.iobus.fdc.armed[1], dut.iobus.fdc.armed[0], dut.iobus.fdc.ins_dly[0],
               dut.iobus.fdc.ins_dly[1], pc_now, tb_cycle);
    end
  end
  // +FDC_TRACE[=n]: every byte the guest writes to the FDC data port and every byte it reads
  // back from it (the first n, default 4000), with the FDC's track registers and the media's
  // request - the controller's own view of a floppy boot.
  integer fdc_trace_n = 0, fdc_trace_cnt = 0;
  reg fdd_err_q = 1'b0;
  initial if ($test$plusargs("FDC_TRACE")) begin
    fdc_trace_n = 4000;
    void'($value$plusargs("FDC_TRACE=%d", fdc_trace_n));
  end
  always @(posedge clk_sys) if (fdc_trace_cnt < fdc_trace_n) begin
    if (dut.iobus.fdc.cs && dut.iobus.fdc.addr == 3'd1 && (dut.iobus.fdc.wr || dut.iobus.fdc.rd)) begin
      $display("FDC %s %02x st=%0d x_st=%0d treg0=%02x pc=%08x cyc=%0d", dut.iobus.fdc.wr ? "W" : "R",
               dut.iobus.fdc.wr ? dut.iobus.fdc.din : dut.iobus.fdc.dout,
               dut.iobus.fdc.st, dut.iobus.fdc.x_st, dut.iobus.fdc.treg[0], pc_now, tb_cycle);
      fdc_trace_cnt = fdc_trace_cnt + 1;
    end
    if (dut.iobus.fdc.media_req) begin
      $display("FDC MEDIA req u=%0d c=%02x h=%02x r=%02x n=%02x hdr=%0d wr=%0d cyc=%0d",
               dut.iobus.fdc.media_unit, dut.iobus.fdc.media_c, dut.iobus.fdc.media_h,
               dut.iobus.fdc.media_r, dut.iobus.fdc.media_n, dut.iobus.fdc.media_req_hdr,
               dut.iobus.fdc.media_wr, tb_cycle);
      fdc_trace_cnt = fdc_trace_cnt + 1;
    end
    if (dut.fdd_err && !fdd_err_q) begin
      $display("FDC MEDIA err cyc=%0d", tb_cycle);
      fdc_trace_cnt = fdc_trace_cnt + 1;
    end
  end
  always @(posedge clk_sys) fdd_err_q <= dut.fdd_err;
  reg [2:0] fdc_st_q = 3'd0;
  always @(posedge clk_sys) begin
    fdc_st_q <= dut.iobus.fdc.st;
    if (fdc_trace_cnt < fdc_trace_n && dut.iobus.fdc.st != fdc_st_q)
      $display("FDC ST %0d->%0d res0=%02x res1=%02x x_st=%0d cyc=%0d", fdc_st_q, dut.iobus.fdc.st,
               dut.iobus.fdc.res0, dut.iobus.fdc.res1, dut.iobus.fdc.x_st, tb_cycle);
  end
  reg [15:0] previous_cs = 16'hffff;
  // TEMP INVESTIGATION PROBE (cell divergences): log every CPU access to 0x481.
  always @(posedge clk_sys) begin
    if (dut.z_valid && ({dut.z_addr, 2'b00} == 32'h00000481))
      $display("PROBE481 pc=%08x wr=%0d data=%08x be=%b cyc=%0d", pc_now, dut.z_write, dut.z_dout, dut.z_be, tb_cycle);
  end
  // --- the HPS block handshake, priced ------------------------------------------
  // `sd_rd -> sd_ack -> req_done` is the one term no tier has ever
  // measured. pc9821_ata issues its block requests from the PIO drain (the
  // `lba_plus1` note in pc9821_ata.sv says when), so this round trip is on the boot's
  // critical path once per sector. This bench mounts the image in-process and acks in the SAME cycle
  // (disk_state 0 above), so the numbers below are the MODEL's handshake latency,
  // NOT the HPS's. The real figure is the ARM reading the sector from SD and
  // streaming 256 words through sys/hps_io.sv; it is measured on the CARD, not here
  // (the telemetry field). `rd2ack` is sd_rd high to sd_ack high;
  // `ack2done` is sd_ack high to the adapter's req_done pulse; `total` is the whole
  // request. One request streams exactly 256 words = one 512-byte sector.
  reg        hps_inflight   = 1'b0;
  reg        hps_acked      = 1'b0;
  reg [63:0] hps_t_rd       = 64'd0;
  reg [63:0] hps_t_ack      = 64'd0;
  integer    hps_req_n      = 0;
  integer    hps_rd2ack_sum = 0, hps_rd2ack_max = 0;
  integer    hps_ack2done_sum = 0, hps_ack2done_max = 0;
  integer    hps_total_sum  = 0, hps_total_max = 0;
  integer lba_log = 0;
  integer cs_log = 0;
  always @(posedge clk_sys) begin
    if (!hps_inflight && img_rd) begin
      hps_inflight <= 1'b1;
      hps_acked    <= 1'b0;
      hps_t_rd      = tb_cycle;
    end else if (hps_inflight) begin
      if (!hps_acked && img_ack) begin
        hps_acked  <= 1'b1;
        hps_t_ack   = tb_cycle;
        hps_rd2ack_sum = hps_rd2ack_sum + (tb_cycle - hps_t_rd);
        if ((tb_cycle - hps_t_rd) > hps_rd2ack_max) hps_rd2ack_max = tb_cycle - hps_t_rd;
      end
      if (dut.block_share.a_req_done) begin
        hps_inflight <= 1'b0;
        hps_req_n     = hps_req_n + 1;
        hps_total_sum = hps_total_sum + (tb_cycle - hps_t_rd);
        if ((tb_cycle - hps_t_rd) > hps_total_max) hps_total_max = tb_cycle - hps_t_rd;
        if (hps_acked) begin
          hps_ack2done_sum = hps_ack2done_sum + (tb_cycle - hps_t_ack);
          if ((tb_cycle - hps_t_ack) > hps_ack2done_max) hps_ack2done_max = tb_cycle - hps_t_ack;
        end
      end
    end
    if (img_rd) begin
      if (lba_log < 400)
        $display("IMG READ lba=%0d (%08x) by=%0x:%08x cyc=%0d",
                 img_lba, img_lba, cpu_cs, cpu_eip, tb_cycle);
      lba_log = lba_log + 1;
    end
    if (cpu_cs != previous_cs) begin
      // Bounded: an option ROM that spins between two segments produced 2.1 M
      // identical lines (a 132 MB log) in one run. The first 400 name the
      // transitions that matter; after that only every 100000th is printed, and
      // the count is always reported.
      if (cs_log < 400 || (cs_log % 100000) == 0)
        $display("CS CHANGE #%0d %04x -> %04x base=%08x eip=%08x pe=%b",
                 cs_log, previous_cs, cpu_cs, cpu_cs_base, cpu_eip, cpu_pe);
      cs_log = cs_log + 1;
      previous_cs <= cpu_cs;
    end
    if (dut.triple_fault_reset)
      $display("TRIPLE FAULT CS:EIP=%04x:%08x", cpu_cs, cpu_eip);
  end

  // ATA command count, at the moment each first command is written. The
  // no-boot-device defect is "no command ever issued"; this makes the opposite
  // observable the instant it happens, without waiting for the exit dump (a run
  // that livelocks never reaches it).
  reg [7:0] ata_cnt_seen = 8'hFF;
  integer   ata_evt_n = 0;
  always @(posedge clk_sys) begin
    if (dut.ata.dbg_cmd_cnt !== ata_cnt_seen && ata_evt_n < 4000) begin
      ata_cnt_seen <= dut.ata.dbg_cmd_cnt;
      ata_evt_n = ata_evt_n + 1;
      // The task file the command was issued with, so a geometry mismatch or a
      // stated-drive disagreement is readable at the moment the ROM commits to it.
      $display("ATA CMD n=%0d last=%02x abort=%0d pc=%08x cyc=%0d cnt=%02x num=%02x cyl=%02x/%02x dh=%02x chs=%b%b idp_hmax=%02x idp_sec=%02x cap=%0d",
               dut.ata.dbg_cmd_cnt, dut.ata.dbg_last_cmd, dut.ata.dbg_abort_cnt,
               pc_now, tb_cycle, dut.ata.sector_count, dut.ata.sector_number,
               dut.ata.cylinder_high, dut.ata.cylinder_low, dut.ata.drive_head,
               dut.ata.chs_sec_ok, dut.ata.chs_head_ok, dut.ata.idp_head_max,
               dut.ata.idp_sectors, dut.ata.capacity);
    end
  end

  // Recent linear program counters. A single sampled EIP cannot distinguish "the
  // CPU is wedged" from "the CPU is looping with all its traffic in cache" --
  // which is exactly the ambiguity the watchdog leaves -- so keep the last few
  // thousand distinct addresses and print the tail as a set.
  localparam integer PC_HIST = 4096;
  reg [31:0] pc_hist [0:PC_HIST-1];
  integer pc_idx = 0;
  reg [31:0] pc_last = 32'hFFFF_FFFF;

  // How long the PC has held one address: a stall and a loop are indistinguishable in
  // a change-triggered trace. Reported at exit; +STOP_ON_STALL ends a run on it.
  //
  // pc_same_uc is how much of that run was spent with a MICROCODED instruction in
  // flight, and it exists because a bare "held N cycles" is actively misleading. A
  // long string instruction (rep stosd, repe scasd) leaves the architectural EIP on
  // its NEXT instruction for the whole duration, so a 128 KiB compare and a jmp $
  // wedge produce the same same-PC run - and this message once sent a hunt for a
  // boot-device blocker at what was the ITF's extended-memory test. The counter is
  // NOT weakened for it: a genuine wedge is still caught by the MEMWEDGE instrument
  // in this file, and a wedge that is itself inside a string op shows up here as a
  // run whose microcoded share is nearly all of it AND whose backend never completes,
  // which MEMWEDGE prints separately.
  reg [31:0] pc_same_cycles = 32'd0;
  reg [31:0] stop_on_stall = 32'd0;
  reg        stalled = 1'b0;
  reg [31:0] pc_same_max    = 32'd0;   // the LONGEST run seen this run
  reg [31:0] pc_same_uc     = 32'd0;   // uc_active cycles in the CURRENT run
  reg [31:0] pc_same_uc_max = 32'd0;   // ...snapshotted for the LONGEST run

  // pc_same_max and pc_same_uc_max are paired on purpose. Reporting the longest
  // microcoded run separately from the longest run reads as nonsense - "held
  // 133020 cycles, 440039 of them microcoded" is what a first attempt printed,
  // with the second number larger than the first because they were maxima over
  // different things. Snapshotting the share AT the moment the longest run is
  // reached makes the second number a genuine subset of the first.
  always @(posedge clk_sys) begin
    if (pc_now != pc_last) begin
      pc_same_cycles <= 32'd1;
      pc_same_uc     <= dut.cpu.uc_active ? 32'd1 : 32'd0;
    end else begin
      if (pc_same_cycles != 32'hFFFF_FFFF)
        pc_same_cycles <= pc_same_cycles + 32'd1;
      if (dut.cpu.uc_active)
        pc_same_uc <= pc_same_uc + 32'd1;
    end
    if (pc_same_cycles > pc_same_max) begin
      pc_same_max    <= pc_same_cycles;
      pc_same_uc_max <= pc_same_uc;
    end
    if (stop_on_stall != 32'd0 && pc_same_cycles >= stop_on_stall)
      stalled <= 1'b1;
  end

  // ---- Measurement controls -------------------------------------------------
  // Every advance in this project came from an instrument, and the cost of a
  // question used to be a testbench edit plus a rebuild plus a full 100M-cycle
  // boot (~5 minutes, since the run is the whole cost: the model build is ~6 s
  // incrementally and measured throughput is ~330k cycles/s). These controls
  // are RUNTIME, so a new question is a command-line flag:
  //
  //   +STOP_AT_CYCLE=<n>        end the run at cycle n
  //   +STOP_AT_PC=<linear addr> end it when the CPU reaches an address
  //                             (the flat pc_now, i.e. what the probes print)
  //   +STOP_AT_PC_HITS=<n>      ... on the n-th visit (default 1)
  //
  // The point is to pay only for the boot up to the interesting moment, and to
  // have every instrument line carry the cycle so "how far in is this?" is
  // answerable from a log. A stopped run SKIPS the acceptance verdict and says
  // so, because a measurement is not an acceptance run.
  reg [63:0] tb_cycle = 64'd0;
  reg        stop_now = 1'b0;
  // +PAST_IPL: run past 1FC0:0000 (see the run_budget block). A measurement mode.
  reg        past_ipl = 1'b0;
  reg        stop_at_pc_valid = 1'b0;
  reg        stop_at_cycle_valid = 1'b0;
  reg [63:0] stop_cycle = 64'hFFFF_FFFF_FFFF_FFFF;
  reg [31:0] stop_pc = 32'hFFFF_FFFF;
  reg [31:0] stop_pc_hits = 32'd1;
  reg [31:0] stop_pc_seen = 32'd0;

  // The plusargs are parsed with %d and %h directly. A %s plusarg lands in a
  // vector right-justified, which a hand-written parser reads backwards --
  // measured, after the first attempt stopped at cycle 143373 instead of
  // 3000000. %h also accepts a bare hex string, so +STOP_AT_PC=fc6b5 works.
  always @(posedge clk_sys) tb_cycle <= tb_cycle + 64'd1;

  // ---- +KEYSEQ: type a scancode sequence at a cycle ----------------------------
  // A boot that stops at a prompt (HSB's "save environment [N/W/R/Q/X]" before the
  // VEM486 #GP, 2026-10-06) needs a keystroke. +KEYSEQ=<hex Set-2 codes, two digits
  // each, first key in the HIGH digits> with +KEYSEQ_N=<count> and +KEYSEQ_AT=<cycle>
  // types them in order: press, KEY_HOLD cycles, release, KEY_GAP cycles.
  // ps2_key is {toggle, pressed, extended, code}; the toggle marks each event.
  localparam integer KEY_HOLD = 400_000, KEY_GAP = 4_000_000;
  reg [127:0] keyseq = 128'd0;
  integer     keyseq_n = 0, keyseq_i = 0;
  reg [63:0]  keyseq_at = 64'hFFFF_FFFF_FFFF_FFFF, keyseq_next = 64'd0;
  reg         keyseq_down = 1'b0, keyseq_tgl = 1'b0;
  initial begin
    void'($value$plusargs("KEYSEQ=%h", keyseq));
    void'($value$plusargs("KEYSEQ_N=%d", keyseq_n));
    if ($value$plusargs("KEYSEQ_AT=%d", keyseq_at)) keyseq_next = keyseq_at;
  end
  always @(posedge clk_sys) begin
    if (keyseq_i < keyseq_n && tb_cycle >= keyseq_at && tb_cycle >= keyseq_next) begin
      keyseq_tgl <= ~keyseq_tgl;
      ps2_key <= {~keyseq_tgl, ~keyseq_down, 1'b0, keyseq[(keyseq_n-1-keyseq_i)*8 +: 8]};
      $display("KEYSEQ %s %02x cyc=%0d", keyseq_down ? "release" : "press",
               keyseq[(keyseq_n-1-keyseq_i)*8 +: 8], tb_cycle);
      if (keyseq_down) begin
        keyseq_i <= keyseq_i + 1;
        keyseq_next <= tb_cycle + KEY_GAP;
      end else
        keyseq_next <= tb_cycle + KEY_HOLD;
      keyseq_down <= ~keyseq_down;
    end
  end

  // ---- +MOUSE_AT / +INPUT_MON: the bus mouse and the keyboard, for a game that reads them ----
  // +MOUSE_AT=<cycle> sends hps_io packets from that cycle on: a left-button press with a
  // +8/+8 move, then a release MOUSE_HOLD cycles later, repeated every MOUSE_GAP cycles
  // (+MOUSE_N=<count>, default 1). +INPUT_MON=<period> prints, every period: the IRQ13 pulses,
  // the 0x7FD9 data reads and the keyboard IRQs since the last line, the mouse's Port C /
  // mode / timing, the slave PIC's IMR/IRR/ISR, the master's, and CS:EIP.
  localparam integer MOUSE_HOLD = 2_000_000, MOUSE_GAP = 20_000_000;
  longint unsigned mouse_at = 0, mouse_next = 0, input_mon = 0;
  integer mouse_n = 1, mouse_i = 0;
  reg mouse_down = 1'b0;
  integer mon_irq13 = 0, mon_rd = 0, mon_kirq = 0;
  reg mon_kirq_d = 1'b0;
  initial begin
    void'($value$plusargs("MOUSE_AT=%d", mouse_at));
    void'($value$plusargs("MOUSE_N=%d", mouse_n));
    void'($value$plusargs("INPUT_MON=%d", input_mon));
    mouse_next = mouse_at;
  end
  always @(posedge clk_sys) begin
    if (mouse_at != 0 && mouse_i < mouse_n && tb_cycle >= mouse_next) begin
      ps2_mouse <= {~ps2_mouse[24], mouse_down ? 8'd0 : 8'hF8, mouse_down ? 8'd0 : 8'd8,
                    5'b00001, 2'b00, ~mouse_down};
      $display("MOUSE %s cyc=%0d", mouse_down ? "release" : "press L", tb_cycle);
      if (mouse_down) begin mouse_i <= mouse_i + 1; mouse_next <= tb_cycle + MOUSE_GAP; end
      else mouse_next <= tb_cycle + MOUSE_HOLD;
      mouse_down <= ~mouse_down;
    end
    mon_kirq_d <= dut.kbd_irq;
    if (dut.mouse_irq) mon_irq13 <= mon_irq13 + 1;
    if (dut.iobus.mouse.rd_a_data) mon_rd <= mon_rd + 1;
    if (dut.kbd_irq && !mon_kirq_d) mon_kirq <= mon_kirq + 1;
    if (input_mon != 0 && tb_cycle != 0 && (tb_cycle % input_mon) == 0) begin
      $display("INPUTMON cyc=%0d irq13=%0d rd7fd9=%0d kbdirq=%0d portc=%02x mode=%02x timing=%0d armed=%0d | slave imr=%02x irr=%02x isr=%02x | master imr=%02x irr=%02x isr=%02x | %04x:%08x if=%0d",
               tb_cycle, mon_irq13, mon_rd, mon_kirq, dut.iobus.mouse.portc, dut.iobus.mouse.mode,
               dut.iobus.mouse.timing, dut.iobus.mouse.tick_armed,
               dut.interrupts.slave.imr, dut.interrupts.slave.ir_latch, dut.interrupts.slave.isr,
               dut.irq_dbg_imr, dut.irq_dbg_irr, dut.irq_dbg_isr, cpu_cs, cpu_eip, dut.cpu.EFLAGS[9]);
      mon_irq13 <= 0; mon_rd <= 0; mon_kirq <= 0;
    end
  end

  // ---- +TRAP_CSEIP: what the CPU was doing when it reached CS:EIP --------------
  // +TRAP_CSEIP=<CS selector:16><EIP:16> (e.g. 00107a86 for VEM486's 0010:7A86 #GP).
  // Each visit prints the full architectural state, the hidden descriptor cache of
  // every segment, and the 16 instruction bytes at CS_base+EIP translated through the
  // guest's own page tables (read from the model's RAM; the L1 is write-through, so
  // the RAM holds every retired store). The run stops after +TRAP_HITS visits
  // (default 1), or on the first #GP/fault raised within TRAP_WIN cycles of a visit.
  // +TRAP_AFTER=<cycle> ignores visits before that cycle, for an address the boot also
  // passes through on its way to the event (the EMM386 hang's disk-BIOS loop).
  localparam integer TRAP_WIN = 2000;
  reg [31:0] trap_cseip = 32'd0;
  reg        trap_en = 1'b0;
  integer    trap_hits = 1, trap_seen = 0, trap_win = 0;
  longint    trap_after = 0;
  // +TRAP_LIN=<linear address> matches the instruction's linear PC instead of CS:EIP,
  // for code whose segment is unknown (the same byte has many real-mode names).
  reg [31:0] trap_lin = 32'd0;
  reg        trap_by_lin = 1'b0;
  reg        trap_wide = 1'b0;
  initial trap_wide = $test$plusargs("TRAP_WIDE");
  initial begin
    if ($value$plusargs("TRAP_CSEIP=%h", trap_cseip)) trap_en = 1'b1;
    if ($value$plusargs("TRAP_LIN=%h", trap_lin)) begin trap_en = 1'b1; trap_by_lin = 1'b1; end
    if (trap_en) begin
      void'($value$plusargs("TRAP_HITS=%d", trap_hits));
      void'($value$plusargs("TRAP_AFTER=%d", trap_after));
    end
  end
  function automatic [31:0] tb_lin2phys(input [31:0] lin);
    reg [31:0] pde, pte;
    begin
      if (!dut.cpu.CR0[31]) tb_lin2phys = lin;
      else begin
        pde = ram[{dut.cpu.CR3[31:12], lin[31:22]} & 32'h00FF_FFFF];
        pte = ram[{pde[31:12], lin[21:12]} & 32'h00FF_FFFF];
        tb_lin2phys = (pde[0] && pte[0]) ? {pte[31:12], lin[11:0]} : 32'hFFFF_FFFF;
        $display("TRAP   walk lin=%08x cr3=%08x pde=%08x pte=%08x -> phys=%08x",
                 lin, dut.cpu.CR3, pde, pte, tb_lin2phys);
      end
    end
  endfunction
  task automatic trap_dump(input [31:0] lin);
    reg [31:0] ph, w0, w1, w2, w3, w4;
    integer k;
    begin
      $display("TRAP state cyc=%0d CS:EIP=%04x:%08x lin=%08x cpl=%0d CR0=%08x CR2=%08x CR3=%08x EFLAGS=%08x",
               tb_cycle, dut.cpu.CS, dut.cpu.EIP, lin, dut.cpu.cpl, dut.cpu.CR0, dut.cpu.CR2,
               dut.cpu.CR3, dut.cpu.EFLAGS);
      $display("TRAP   EAX=%08x EBX=%08x ECX=%08x EDX=%08x ESI=%08x EDI=%08x EBP=%08x ESP=%08x",
               dut.cpu.EAX, dut.cpu.EBX, dut.cpu.ECX, dut.cpu.EDX, dut.cpu.ESI, dut.cpu.EDI,
               dut.cpu.EBP, dut.cpu.ESP);
      $display("TRAP   sel ES=%04x CS=%04x SS=%04x DS=%04x FS=%04x GS=%04x",
               dut.cpu.ES, dut.cpu.CS, dut.cpu.SS, dut.cpu.DS, dut.cpu.FS, dut.cpu.GS);
      for (k = 0; k < 8; k = k + 1)
        $display("TRAP   desc[%0d %s] base=%08x limit=%05x G=%0d D/B=%0d type=%x S=%0d DPL=%0d P=%0d",
                 k, (k==0)?"ES":(k==1)?"CS":(k==2)?"SS":(k==3)?"DS":(k==4)?"FS":(k==5)?"GS":(k==6)?"TR":"LDTR",
                 dut.cpu.desc_cache[k].base, dut.cpu.desc_cache[k].limit, dut.cpu.desc_cache[k].G,
                 dut.cpu.desc_cache[k].D_B, dut.cpu.desc_cache[k].seg_type, dut.cpu.desc_cache[k].S,
                 dut.cpu.desc_cache[k].DPL, dut.cpu.desc_cache[k].P);
      ph = tb_lin2phys(lin);
      if (ph != 32'hFFFF_FFFF) begin
        w0 = ram[(ph >> 2)     & 32'h00FF_FFFF]; w1 = ram[((ph >> 2) + 1) & 32'h00FF_FFFF];
        w2 = ram[((ph >> 2) + 2) & 32'h00FF_FFFF]; w3 = ram[((ph >> 2) + 3) & 32'h00FF_FFFF];
        w4 = ram[((ph >> 2) + 4) & 32'h00FF_FFFF];
        // Little-endian bytes from the dword containing phys, then the four after it;
        // the first instruction byte is at offset phys[1:0] of the first dword.
        $display("TRAP   bytes@phys %08x (dword-aligned, insn at +%0d): %02x %02x %02x %02x  %02x %02x %02x %02x  %02x %02x %02x %02x  %02x %02x %02x %02x  %02x %02x %02x %02x",
                 ph & 32'hFFFF_FFFC, ph[1:0],
                 w0[7:0], w0[15:8], w0[23:16], w0[31:24], w1[7:0], w1[15:8], w1[23:16], w1[31:24],
                 w2[7:0], w2[15:8], w2[23:16], w2[31:24], w3[7:0], w3[15:8], w3[23:16], w3[31:24],
                 w4[7:0], w4[15:8], w4[23:16], w4[31:24]);
      end
      // +TRAP_WIDE: the code around the trap (0x100 bytes before, 0x40 after) and the
      // top 0x40 bytes of the stack, so a caller and its return path can be disassembled.
      if (trap_wide && ph != 32'hFFFF_FFFF) trap_hex("TRAP code", (ph & 32'hFFFF_FFF0) - 32'h100, 20);
      if (trap_wide) trap_hex("TRAP stack", tb_lin2phys(dut.cpu.desc_cache[2].base + (dut.cpu.ESP & 32'hFFFF)), 4);
      if (trap_ramfile != "") trap_dump_ram();
      dump_pc_tail();
    end
  endtask
  // +TRAP_RAMFILE=<path>: the guest's first 0x110000 bytes of RAM as a raw binary at the
  // first trap visit (real-mode code, the HMA included), for offline disassembly.
  string trap_ramfile = "";
  initial void'($value$plusargs("TRAP_RAMFILE=%s", trap_ramfile));
  // +TRAP_RAMBYTES=<n>: dump n bytes instead (extended memory, e.g. 400000 for 4 MiB).
  longint trap_rambytes = 64'h110000;
  initial void'($value$plusargs("TRAP_RAMBYTES=%h", trap_rambytes));
  task automatic trap_dump_ram;
    integer fd, a;
    reg [31:0] w;
    begin
      fd = $fopen(trap_ramfile, "wb");
      for (a = 0; a < trap_rambytes / 4; a = a + 1) begin
        w = ram[a];
        $fwrite(fd, "%c%c%c%c", w[7:0], w[15:8], w[23:16], w[31:24]);
      end
      $fclose(fd);
      $display("TRAP ram 0..0x%0h written to %s", trap_rambytes - 1, trap_ramfile);
      trap_ramfile = "";
    end
  endtask
  task automatic trap_hex(input string tag, input [31:0] base, input integer rows);
    reg [31:0] w;
    integer r, c;
    begin
      for (r = 0; r < rows; r = r + 1) begin
        $write("%s %08x:", tag, base + r * 16);
        for (c = 0; c < 4; c = c + 1) begin
          w = ram[((base + r * 16 + c * 4) >> 2) & 32'h00FF_FFFF];
          $write(" %02x %02x %02x %02x", w[7:0], w[15:8], w[23:16], w[31:24]);
        end
        $write("\n");
      end
    end
  endtask
  always @(posedge clk_sys) begin
    if (trap_en && !stop_now && (tb_cycle >= trap_after)) begin
      if ((trap_by_lin ? (pc_now == trap_lin)
                       : ((cpu_cs == trap_cseip[31:16]) && (cpu_eip == {16'd0, trap_cseip[15:0]}))) &&
          (pc_now != pc_last)) begin
        trap_seen = trap_seen + 1;
        $display("TRAP visit #%0d at %04x:%08x cyc=%0d", trap_seen, cpu_cs, cpu_eip, tb_cycle);
        trap_dump(pc_now);
        trap_win = TRAP_WIN;
        if (trap_seen >= trap_hits) begin
          $display("MEASURE stop=trap hits=%0d cyc=%0d", trap_seen, tb_cycle);
          stop_now <= 1'b1;
        end
      end else if (trap_win > 0) begin
        trap_win = trap_win - 1;
        if (dut.cpu.any_fault_r || dut.cpu.gp_fault_trigger) begin
          $display("TRAP fault within %0d cycles of the visit: any_fault_r=%0d gp_fault_trigger=%0d pc=%08x",
                   TRAP_WIN - trap_win, dut.cpu.any_fault_r, dut.cpu.gp_fault_trigger, pc_now);
          trap_dump(pc_now);
          $display("MEASURE stop=trap-fault cyc=%0d", tb_cycle);
          stop_now <= 1'b1;
        end
      end
    end
  end

  // ---- the DOS-extender / EMM386 signature, and the paging fault -----------
  // EMM386 is a PAGING memory manager: its EMS page frame and /UMB UMBs are PTE
  // writes made live with `mov cr3,eax`, so
  // the first V86 entry and the first CR0.PG enable are its signature, and a #PF is
  // where a paging path goes wrong. All three are bounded - a wedge that faults
  // every cycle must not produce a 132 MB log.
  reg v86_seen = 1'b0, pg_seen = 1'b0;
  integer pf_log = 0;
  always @(posedge clk_sys) begin
    if (dut.cpu.dbg_vm && !v86_seen) begin
      v86_seen <= 1'b1;
      $display("V86 ENTER cyc=%0d pc=%08x cs=%04x", tb_cycle, pc_now, cpu_cs);
    end
    if (dut.cpu.CR0[31] && !pg_seen) begin
      pg_seen <= 1'b1;
      $display("PAGING ON cyc=%0d pc=%08x cr3=%08x", tb_cycle, pc_now, dut.cpu.CR3);
    end
    if (dut.cpu.page_fault && pf_log < 200) begin
      $display("PFAULT #%0d cyc=%0d pc=%08x cr2=%08x cr3=%08x code=%0d", pf_log,
               tb_cycle, pc_now, dut.cpu.pg_cr2_out, dut.cpu.CR3, dut.cpu.pg_fault_code);
      pf_log = pf_log + 1;
    end
  end

  always @(posedge clk_sys) begin
    if (!stop_now) begin
      if (stop_at_cycle_valid && tb_cycle >= stop_cycle) begin
        $display("MEASURE stop=cycle cyc=%0d", tb_cycle);
        stop_now <= 1'b1;
      end else if (stop_at_pc_valid && pc_now[31:4] == stop_pc[31:4]) begin
        stop_pc_seen <= stop_pc_seen + 32'd1;
        if (stop_pc_seen + 32'd1 >= stop_pc_hits) begin
          // Matched on the 16-byte block, because pc_now only ever holds
          // instruction START addresses: an exact comparison against an
          // address that is mid-instruction never fires, which is exactly
          // what a first attempt at +STOP_AT_PC=fc6b5 measured (the whole
          // 100M-cycle budget elapsed). Printing the exact pc_now says where
          // the CPU actually was.
          $display("MEASURE stop=pc want=%08x at=%08x hits=%0d cyc=%0d", stop_pc,
                   pc_now, stop_pc_seen + 32'd1, tb_cycle);
          stop_now <= 1'b1;
        end
      end
    end
  end
  always @(posedge clk_sys) begin
    if (pc_now != pc_last) begin
      pc_hist[pc_idx % PC_HIST] <= pc_now;
      pc_idx <= pc_idx + 1;
      pc_last <= pc_now;
    end
  end

  // --- a long-boot progress view (any build) -------------------------------------
  // +PC_SAMPLE=<n>: one line of CS:EIP and the mode bits every n cycles, so a guest that
  // spins for minutes can be located without a trap address. +TEXT_EVERY=<n>: the text
  // screen every n cycles. +IOLOG_AFTER=<cycle> (+IOLOG_N=<n>, default 4000): every device
  // I/O access after that cycle, with the instruction that made it. +IOLOG_CS=<hex>: start
  // the log instead at the first instruction issued with that CS (a guest's own segment).
  longint unsigned pc_sample = 0, text_every = 0, iolog_after = 0;
  integer iolog_n = 4000, iolog_cnt = 0;
  reg [15:0] iolog_cs = 16'h0;
  reg iolog_all = 1'b0, iolog_land_q = 1'b0;
  initial begin
    iolog_all = $test$plusargs("IOLOG_ALL");
    void'($value$plusargs("IOLOG_CS=%h", iolog_cs));
    void'($value$plusargs("PC_SAMPLE=%d", pc_sample));
    void'($value$plusargs("TEXT_EVERY=%d", text_every));
    void'($value$plusargs("IOLOG_AFTER=%d", iolog_after));
    void'($value$plusargs("IOLOG_N=%d", iolog_n));
  end
  // +ITRACE_CSEIP=<cs:eip as 8 hex digits> (+ITRACE_N=<n>, default 200; +ITRACE_HITS=<k>,
  // default 4): from each of the first k issues at that CS:IP, the next n issued
  // instructions with SP, EFLAGS and SS base, and every CPU memory write accepted meanwhile -
  // the same view as the hardware's --dbg-trig ring, for a side-by-side comparison.
  reg [31:0] itrace_cseip = 32'h0;
  integer itrace_n = 200, itrace_hits = 4, itrace_left = 0, itrace_seen = 0;
  // +ITRACE_AFTER=<cycle>: ignore issues at ITRACE_CSEIP before that cycle (a hot address).
  longint unsigned itrace_after = 0;
  initial begin
    void'($value$plusargs("ITRACE_AFTER=%d", itrace_after));
    void'($value$plusargs("ITRACE_CSEIP=%h", itrace_cseip));
    void'($value$plusargs("ITRACE_N=%d", itrace_n));
    void'($value$plusargs("ITRACE_HITS=%d", itrace_hits));
  end
  always @(posedge clk_sys) begin
    if (itrace_cseip != 0 && dut.cpu_dbg_issue) begin
      if (itrace_left == 0 && itrace_seen < itrace_hits && tb_cycle >= itrace_after &&
          cpu_cs == itrace_cseip[31:16] &&
          dut.cpu_dbg_issue_eip[15:0] == itrace_cseip[15:0]) begin
        itrace_left = itrace_n;
        itrace_seen = itrace_seen + 1;
        $display("ITRACE hit %0d at cyc=%0d", itrace_seen, tb_cycle);
      end
      if (itrace_left != 0) begin
        $display("ITRACE %04x:%08x sp=%04x fl=%04x ssb=%08x cyc=%0d", cpu_cs,
                 dut.cpu_dbg_issue_eip, dut.cpu_dbg_SP, dut.cpu_dbg_eflags[15:0],
                 dut.cpu.desc_cache[2].base, tb_cycle);
        itrace_left = itrace_left - 1;
      end
    end
    if (itrace_left != 0 && dut.cpu_mem_valid && dut.mem_cpu_ready)
      $display("ITRACE   MEM %s a=%08x be=%b d=%08x line=%0d cyc=%0d", dut.z_write ? "WR" : "RD",
               {dut.z_addr, 2'b00}, dut.z_be, dut.z_dout, dut.z_line_read, tb_cycle);
    if (pc_sample != 0 && tb_cycle != 0 && (tb_cycle % pc_sample) == 0)
      $display("PCS cyc=%0d %04x:%08x lin=%08x pe=%0d vm=%0d", tb_cycle, cpu_cs, cpu_eip,
               pc_now, cpu_pe, dut.cpu.dbg_vm);
    if (text_every != 0 && tb_cycle != 0 && (tb_cycle % text_every) == 0) begin
      $display("TEXT at cyc=%0d", tb_cycle);
      dump_tram_text;
    end
    if (iolog_cs != 0 && iolog_after == 0 && cpu_cs == iolog_cs) begin
      iolog_after = tb_cycle;
      $display("IOLOG start: CS=%04x at cyc=%0d", iolog_cs, tb_cycle);
    end
    // +IOLOG_ALL: every port the I/O bus serves (FDC, DMA, PIT, system ports included), read
    // from the bus's own last-access latch the cycle after it lands; the default view is the
    // device fabric only.
    iolog_land_q <= (dut.iobus.state == dut.iobus.S_BYTE &&
                     !(dut.iobus.device_port && !dut.iobus.request_write && dut.iobus.device_rd_wait)) ||
                    dut.iobus.state == dut.iobus.S_DEVWAIT;
    if (iolog_all && iolog_after != 0 && tb_cycle >= iolog_after && iolog_cnt < iolog_n &&
        iolog_land_q) begin
      $display("IOLOG %s %04x %s=%02x at %04x:%08x pe=%0d vm=%0d cyc=%0d",
               dut.dbg_last_io_wr ? "OUT" : "IN ", dut.dbg_last_io_addr,
               dut.dbg_last_io_wr ? "d" : "q", dut.dbg_last_io_data,
               cpu_cs, cpu_eip, cpu_pe, dut.cpu.dbg_vm, tb_cycle);
      iolog_cnt = iolog_cnt + 1;
    end
    if (!iolog_all && iolog_after != 0 && tb_cycle >= iolog_after && iolog_cnt < iolog_n &&
        (dut.device_io_wr || dut.device_io_rd)) begin
      $display("IOLOG %s %04x %s=%02x at %04x:%08x pe=%0d vm=%0d cyc=%0d",
               dut.device_io_wr ? "OUT" : "IN ", dut.device_io_addr,
               dut.device_io_wr ? "d" : "q", dut.device_io_wr ? dut.device_io_din : dut.device_io_dout,
               cpu_cs, cpu_eip, cpu_pe, dut.cpu.dbg_vm, tb_cycle);
      iolog_cnt = iolog_cnt + 1;
    end
  end

  // --- CS=0 separation probe ------------------------------------
  // The ITF's phase-1 tail copies a 240-byte script to physical 0 and jumps to
  // it. Two failures look identical on the PC: the copy never landed (a
  // store-path or memory-map defect) or it landed and the FETCH served something
  // else. This probe separates them in one run. On the FIRST real-mode low-RAM
  // entry after the final POST pass (a cycle gate past pass 2's MODERESET, so it
  // can only be the pass-3 runaway) it dumps:
  //   - the SDRAM bytes at physical 0..0xEF (the copy's destination),
  //   - the (pc, cycle) trace of every distinct PC since 69.0M,
  //   - the I-cache lines the CPU was actually SERVED (not the pack's bytes),
  //   - the firmware top window's shadow/pack bytes and the z486 external bus,
  //   - whether the tail block (0xF8167..0xF8180) ever ran at all.
  // The run that used it decided the failure was NOT the
  // 0x181 `jmp 0:0` and NOT L1 coherence: the fetch at 0xF9A10 was served the
  // firmware-window SHADOW (see pc9821_memory_map's fw_shadow_read).
  reg        cs0_probed = 1'b0;
  reg [15:0] cs0_wait   = 16'd0;
  integer    cs0_w, cs0_k, cs0_k2;
  integer    cs0_tail_hits = 0;   // PCs in 0xF8167..0xF8180 since the gate
  integer    cs0_jmp_hits  = 0;   // PCs at 0xF8181 (the jmp 0:0) since the gate
  integer    cs0_low_stores = 0;  // CPU stores into the first page since 60M cycles
  integer    cs0_gp_hits = 0, cs0_pf_hits = 0, cs0_win_n = 0;
  localparam integer CS0_TRACE = 256;
  reg [31:0] cs0_pc  [0:CS0_TRACE-1];
  reg [63:0] cs0_cyc [0:CS0_TRACE-1];
  integer    cs0_idx = 0;
  reg [31:0] cs0_pclast = 32'hFFFF_FFFF;
  localparam integer CS0_IFR = 16;
  reg [63:0]  cs0_if_cyc  [0:CS0_IFR-1];
  reg [31:0]  cs0_if_addr [0:CS0_IFR-1];
  reg [127:0] cs0_if_line [0:CS0_IFR-1];
  integer     cs0_if_idx = 0;
  localparam integer CS0_ZBUS = 32;
  reg [63:0] cs0_z_cyc  [0:CS0_ZBUS-1];
  reg [31:0] cs0_z_addr [0:CS0_ZBUS-1];
  reg [31:0] cs0_z_pc   [0:CS0_ZBUS-1];
  reg        cs0_z_we   [0:CS0_ZBUS-1];
  reg        cs0_z_io   [0:CS0_ZBUS-1];
  integer    cs0_z_idx = 0;
  localparam integer CS0_BUS = 32;
  reg [31:0] cs0_bus_addr [0:CS0_BUS-1];
  reg [31:0] cs0_bus_pc   [0:CS0_BUS-1];
  reg        cs0_bus_we   [0:CS0_BUS-1];
  integer    cs0_bus_idx = 0;
  // What the memory subsystem actually returns for the instruction window's
  // lines, and in which mode. Bounded and range-gated so a healthy boot prints
  // a handful of lines at most.
  always @(posedge clk_sys) begin
    if (!cs0_probed && (tb_cycle > 69_000_000) && dut.memory.cpu_valid &&
        dut.memory.cpu_ready && !dut.memory.cpu_write &&
        (dut.memory.cpu_addr >= 32'h000F_9000) && (dut.memory.cpu_addr <= 32'h000F_A2FF) &&
        (cs0_win_n < 16)) begin
      cs0_win_n = cs0_win_n + 1;
      // The 128-bit line mux this probe used to print is gone (P3): a line read is four word
      // beats, so the probe shows the beat the boundary is presenting this cycle.
      $display("CS0 WINRD cyc=%0d addr=%08x bc=%0d line=%b shadow=%b dirty=%b gate=%b top_bank=%0d word=%08x",
               tb_cycle, dut.memory.cpu_addr, dut.memory.cpu_burstcount,
               dut.memory.cpu_line_read, dut.memory.top_shadow_en,
               dut.memory.fw_shadow_dirty, dut.memory.bios_ram_gate,
               dut.memory.top_bank, dut.memory.cpu_dout);
    end
  end
  function automatic [7:0] ram_byte(input [31:0] addr);
    ram_byte = ram[addr >> 2] >> (((addr % 4) * 8));
  endfunction
  always @(posedge clk_sys) begin
    if (!cs0_probed && (tb_cycle > 69_000_000)) begin
      if (pc_now != cs0_pclast) begin
        cs0_pc[cs0_idx % CS0_TRACE]  = pc_now;
        cs0_cyc[cs0_idx % CS0_TRACE] = tb_cycle;
        cs0_idx = cs0_idx + 1;
        cs0_pclast = pc_now;
        if ((pc_now >= 32'h000F_8167) && (pc_now <= 32'h000F_8180)) cs0_tail_hits = cs0_tail_hits + 1;
        if (pc_now == 32'h000F_8181) cs0_jmp_hits = cs0_jmp_hits + 1;
      end
      if (dut.cpu.memory_inst.cache_unit_inst.icache_inst.cpu_resp_valid) begin
        cs0_if_cyc[cs0_if_idx % CS0_IFR]  = tb_cycle;
        cs0_if_addr[cs0_if_idx % CS0_IFR] = dut.cpu.memory_inst.cache_unit_inst.icache_inst.req_addr_r;
        cs0_if_line[cs0_if_idx % CS0_IFR] = dut.cpu.memory_inst.cache_unit_inst.icache_inst.cpu_line;
        cs0_if_idx = cs0_if_idx + 1;
      end
      if (dut.z_valid && dut.z_ready) begin
        cs0_z_cyc[cs0_z_idx % CS0_ZBUS]  = tb_cycle;
        cs0_z_addr[cs0_z_idx % CS0_ZBUS] = dut.z_addr;
        cs0_z_pc[cs0_z_idx % CS0_ZBUS]   = pc_now;
        cs0_z_we[cs0_z_idx % CS0_ZBUS]   = dut.z_write;
        cs0_z_io[cs0_z_idx % CS0_ZBUS]   = dut.z_io;
        cs0_z_idx = cs0_z_idx + 1;
      end
      if (dut.memory.cpu_valid && dut.memory.cpu_ready) begin
        cs0_bus_addr[cs0_bus_idx % CS0_BUS] = dut.memory.cpu_addr;
        cs0_bus_pc[cs0_bus_idx % CS0_BUS]   = pc_now;
        cs0_bus_we[cs0_bus_idx % CS0_BUS]   = dut.memory.cpu_write;
        cs0_bus_idx = cs0_bus_idx + 1;
      end
      if (dut.cpu.gp_fault_trigger) cs0_gp_hits = cs0_gp_hits + 1;
      if (dut.cpu.page_fault)       cs0_pf_hits = cs0_pf_hits + 1;
    end
    if ((tb_cycle > 60_000_000) && dut.memory.cpu_valid && dut.memory.cpu_ready &&
        dut.memory.cpu_write && (dut.memory.cpu_addr < 32'h1000))
      cs0_low_stores = cs0_low_stores + 1;
    if (!cs0_probed && (cpu_cs == 16'h0000) && !cpu_pe && (tb_cycle > 68_000_000)) begin
      cs0_probed <= 1'b1;
      cs0_wait   <= 16'd0;
      $display("CS0 PROBE latch cyc=%0d pc=%08x cs=%04x eip=%08x tail_hits=%0d jmp181=%0d lowstores=%0d gp=%0d pf=%0d",
               tb_cycle, pc_now, cpu_cs, cpu_eip, cs0_tail_hits, cs0_jmp_hits,
               cs0_low_stores, cs0_gp_hits, cs0_pf_hits);
      $write("  SDRAM 0000..00EF:");
      for (cs0_w = 0; cs0_w < 16'h00F0; cs0_w = cs0_w + 1) begin
        if ((cs0_w % 16) == 0) $write("\n  %04x:", cs0_w);
        $write(" %02x", ram_byte(cs0_w[31:0]));
      end
      $write("\n  EXEC TRACE (pc@cyc, oldest first):");
      for (cs0_k = 0; cs0_k < CS0_TRACE; cs0_k = cs0_k + 1) begin
        if ((cs0_k % 4) == 0) $write("\n  ");
        $write(" %08x@%0d", cs0_pc[(cs0_idx - CS0_TRACE + cs0_k + CS0_TRACE*2) % CS0_TRACE],
               cs0_cyc[(cs0_idx - CS0_TRACE + cs0_k + CS0_TRACE*2) % CS0_TRACE]);
      end
      $write("\n  LAST %0d I-CACHE SERVES (addr line@cyc):", CS0_IFR);
      for (cs0_k = 0; cs0_k < CS0_IFR; cs0_k = cs0_k + 1) begin
        $write("\n  ");
        $write("%08x %032x@%0d",
               cs0_if_addr[(cs0_if_idx - CS0_IFR + cs0_k + CS0_IFR*2) % CS0_IFR],
               cs0_if_line[(cs0_if_idx - CS0_IFR + cs0_k + CS0_IFR*2) % CS0_IFR],
               cs0_if_cyc[(cs0_if_idx - CS0_IFR + cs0_k + CS0_IFR*2) % CS0_IFR]);
      end
      $write("\n  LAST %0d Z486 EXT BUS (we io addr cyc pc):", CS0_ZBUS);
      for (cs0_k = 0; cs0_k < CS0_ZBUS; cs0_k = cs0_k + 1) begin
        if ((cs0_k % 2) == 0) $write("\n  ");
        $write(" %s%s %08x @%0d @%08x",
               cs0_z_we[(cs0_z_idx - CS0_ZBUS + cs0_k + CS0_ZBUS*2) % CS0_ZBUS] ? "w" : "r",
               cs0_z_io[(cs0_z_idx - CS0_ZBUS + cs0_k + CS0_ZBUS*2) % CS0_ZBUS] ? "io" : "  ",
               cs0_z_addr[(cs0_z_idx - CS0_ZBUS + cs0_k + CS0_ZBUS*2) % CS0_ZBUS],
               cs0_z_cyc[(cs0_z_idx - CS0_ZBUS + cs0_k + CS0_ZBUS*2) % CS0_ZBUS],
               cs0_z_pc[(cs0_z_idx - CS0_ZBUS + cs0_k + CS0_ZBUS*2) % CS0_ZBUS]);
      end
      $write("\n  SHADOW base=%08x pack_base=%08x dirty=%b; SHADOW 1a00..1a2F:",
             dut.memory.fw_shadow_base, dut.memory.pack_base, dut.memory.fw_shadow_dirty);
      for (cs0_k2 = 0; cs0_k2 < 48; cs0_k2 = cs0_k2 + 1)
        $write(" %02x", ram_byte(dut.memory.fw_shadow_base + 32'h1a00 + cs0_k2[31:0]));
      $write("\n  ICACHE state=%0d tag=%0x set=%0x line=%032x",
             dut.cpu.memory_inst.cache_unit_inst.icache_inst.state,
             dut.cpu.memory_inst.cache_unit_inst.icache_inst.req_tag_r,
             dut.cpu.memory_inst.cache_unit_inst.icache_inst.req_set_r,
             dut.cpu.memory_inst.cache_unit_inst.icache_inst.fill_line);
      $write("\n");
    end else if (cs0_probed && (cs0_wait != 16'hFFFF)) begin
      cs0_wait <= cs0_wait + 16'd1;
      if (cs0_wait == 16'h0FFF) begin
        $write("CS0 PROBE +4096 SDRAM 0000..001F:");
        for (cs0_w = 0; cs0_w < 16'h0020; cs0_w = cs0_w + 1)
          $write(" %02x", ram_byte(cs0_w[31:0]));
        $write("\n");
      end
    end
  end

  // --- post-hand-off trajectory ---------------------------------------------
  // The ITF hands the machine to the main BIOS with `jmp 0:0x4F8` (BANK4@0xFA3D4),
  // whose low-RAM stub does `out 0x43D,al` then `jmp 0xFD80:0x0002` (BANK7@0xFD83D
  // writes the same stub shape for the reset). After that the run has no telemetry
  // of its own: the PC sampler in this file covers only the last 64k cycles, and the
  // CS-change trace only fires on a SEGMENT change, which a main BIOS looping inside
  // CS=FD80 never makes. So a freeze there is silent for the whole 100M budget. This
  // samples the architectural state every HO_TICK_DIV cycles once the hand-off is
  // seen (CS=0 in real mode past 69M, so it cannot be the phase-1 `jmp 0:0`), which
  // is the trajectory a wedge report needs: does CS reach FD80, and is CR0.PG or V86
  // ever entered.
  reg        handoff_seen = 1'b0;
  integer    ho_tick  = 0;
  integer    ho_lines = 0;
  localparam integer HO_TICK_DIV = 500_000;
  localparam integer HO_MAX      = 200;
  // The IDE option ROM's ARTIC-based delay (BANK3@0x8B16-0x8B3E): its disassembly flags it as
  // "unbounded in form - relying on port 0x5E advancing", called from the ATA soft reset
  // and the long retry pacing. Latched entry/exit names the cycle it starts and ends, and
  // artic_cnt says whether the counter moved, so a wedge here cannot be read as a stall.
  // The line also carries the delay's CALLER, the three cells an earlier run named
  // (the BIOS work area's IDE word at 0x642, the ROM's I/O-wait accounting [es:0x2060]
  // and its sector count [es:0x200A]), the ATA task file, and the requested time in
  // 0x5E units. The window is the delay routine alone, so the caller pc is real.
  reg        idedelay_in = 1'b0;
  integer    idedelay_n  = 0;
  reg [15:0] idedelay_hi = 16'd0;
  reg [63:0] idedelay_cyc = 64'd0;
  localparam integer IDEDELAY_MAX = 600;
  integer    idw_n = 0;
  integer    idw_63d = 0;
  reg        idw_501_seen = 1'b0;
  always @(posedge clk_sys) begin
    if (!handoff_seen && (cpu_cs == 16'h0000) && !cpu_pe && (tb_cycle > 69_000_000))
      handoff_seen <= 1'b1;
    else if (handoff_seen) begin
      if (ho_tick >= HO_TICK_DIV - 1) begin
        ho_tick = 0;
        if (ho_lines < HO_MAX) begin
          ho_lines = ho_lines + 1;
          $display("HANDOFF cyc=%0d cs=%04x eip=%08x pc=%08x pe=%b vm=%b pg=%b cr3=%08x top_bank=%0d artic=%06x",
                   tb_cycle, cpu_cs, cpu_eip, pc_now, cpu_pe, dut.cpu.dbg_vm,
                   dut.cpu.CR0[31], dut.cpu.CR3, dut.iobus.top_bank, dut.iobus.artic_cnt[23:0]);
        end
      end else begin
        ho_tick = ho_tick + 1;
      end
    end
    if (pc_now >= 32'h000D_8B16 && pc_now <= 32'h000D_8B3E) begin
      if (!idedelay_in) begin
        idedelay_in <= 1'b1;
        idedelay_hi = dut.iobus.artic_cnt[23:8];
        idedelay_cyc = tb_cycle;
        if (idedelay_n < IDEDELAY_MAX) begin
          idedelay_n = idedelay_n + 1;
          $display("IDEDELAY ENTER #%0d cyc=%0d pc=%08x caller=%08x cx=%04x artic=%06x ram642=%08x ramDA060=%08x ramDA00A=%08x ata=err%02x st%02x cnt%02x num%02x cyl%02x/%02x dh%02x",
                   idedelay_n, tb_cycle, pc_now, pc_last, dut.cpu.data_unit_inst.ecx[15:0],
                   dut.iobus.artic_cnt[23:0],
                   ram[32'h0000_0642 >> 2], ram[32'h000D_A060 >> 2],
                   ram[32'h000D_A00A >> 2],
                   dut.ata.error_reg, dut.ata.status_reg, dut.ata.sector_count,
                   dut.ata.sector_number, dut.ata.cylinder_high, dut.ata.cylinder_low,
                   dut.ata.drive_head);
        end
      end
    end else if (idedelay_in) begin
      idedelay_in <= 1'b0;
      if (idedelay_n <= IDEDELAY_MAX)
        // cx= on the ENTER line is the ROM's REQUEST in 0x5E units; units= here is the
        // counter's own advance, which under +ARTIC_BOOST includes the forced jump (it
        // is the request only in an unboosted run). cyc= is the cost either way.
        $display("IDEDELAY EXIT  #%0d cyc=%0d pc=%08x units=%0d cost=%0d", idedelay_n,
                 tb_cycle, pc_now, dut.iobus.artic_cnt[23:8] - idedelay_hi,
                 tb_cycle - idedelay_cyc);
    end
    // Which work RAM the IDE option ROM picked. BANK3@0x8B40 (called from its
    // entry in the 0xD8000 window) chooses ES from [0x501] bit 3 and port 0x63D
    // bit 1: 0xD800, or 0xE600, or 0xE800. The last two put the ROM's own state
    // at 0xE8000-0xEBFFF, which the mapper serves from the firmware pack.
    if ((tb_cycle > 75_000_000) && dut.z_valid && dut.z_ready && !dut.z_io &&
        (dut.z_addr >= 30'h0003_A000) && (dut.z_addr <= 30'h0003_AFFF) && idw_n < 16) begin
      idw_n = idw_n + 1;
      $display("IDEWORK %s addr=%08x data=%08x be=%b cyc=%0d",
               dut.z_write ? "w" : "r", {dut.z_addr, 2'b00}, dut.z_dout[31:0],
               dut.z_be, tb_cycle);
    end
    if (dut.iobus.port_addr == 16'h063D && dut.iobus.lane == 2'd0 &&
        dut.iobus.state == pc9821_ports_pkg::S_IOWAIT && !dut.iobus.request_write && idw_63d < 4) begin
      idw_63d = idw_63d + 1;
      $display("IDE 63D read = %02x at cyc=%0d pc=%08x", dut.iobus.lane_rdata, tb_cycle, pc_now);
    end
    if (!idw_501_seen && (tb_cycle > 75_000_000)) begin
      idw_501_seen <= 1'b1;
      $display("IDE 501 bit3 = %b (ram[500]=%02x ram[501]=%02x) at cyc=%0d",
               ram[32'h0000_0500 >> 2][11], ram[32'h0000_0500 >> 2][7:0],
               ram[32'h0000_0500 >> 2][15:8], tb_cycle);
    end
  end

  // --- every ARTIC-based wait routine, counted ------------------------
  // An earlier measurement left one number unmeasured: HOW MANY times a boot pays a 4-second
  // settle. The option ROM's 202 M-cycle delay (BANK3@0x8B16) is only one home of
  // the ARTIC wait; the firmware carries three more, and the option ROM's own settle
  // routine (0x81F3, which runs `delay(121*(0x28-[es:0x2060]))` = 4,840 units at
  // 0x8222) is called from four sites - drive init (0xD833B), the per-command issue
  // path (0xD83A5), RECALIBRATE (0xD8557) and the read settle (0xD8590). Whether a
  // call actually pays the 4 s depends on the per-slot `[es:bx+2]` cell (set at
  // 0x8279-0x8280 only when `[0x5ba]` names the drive): a call whose cell is already
  // set skips it. This counter is what turns "argued" into "counted".
  //
  //   1  0x000D_8B16..0x000D_8B3E  option ROM delay         (port 0x5E, 2-byte)
  //   2  0x000F_5B62..0x000F_5B8B  main BIOS copy of it      (port 0x5E, 2-byte)
  //   3  0x000F_8E11..0x000F_8E2E  main BIOS elapsed timer    (port 0x5C, word)
  //   4  0x000F_EE42..0x000F_EE9A  main BIOS device timeout   (port 0x5E, 2-byte)
  //
  // An ENTRY is the first cycle inside a window after not being inside it. cx= is the
  // request read out of the CPU's own register file. Under +ARTIC_BOOST the per-entry
  // cost is the model's collapsed price; the entry COUNT is exact either way and the
  // cost is authentic only in an unboosted run.
  function automatic [2:0] artic_wait_id(input [31:0] p);
    begin
      if      ((p >= 32'h000D_8B16) && (p <= 32'h000D_8B3E)) artic_wait_id = 3'd1;
      else if ((p >= 32'h000F_5B62) && (p <= 32'h000F_5B8B)) artic_wait_id = 3'd2;
      else if ((p >= 32'h000F_8E11) && (p <= 32'h000F_8E2E)) artic_wait_id = 3'd3;
      else if ((p >= 32'h000F_EE42) && (p <= 32'h000F_EE9A)) artic_wait_id = 3'd4;
      else                                                  artic_wait_id = 3'd0;
    end
  endfunction
  reg [2:0]  wait_id_prev = 3'd0;
  reg [63:0] wait_t0      = 64'd0;
  integer    wait_n       = 0;
  integer    wait_cnt [0:4];
  integer    wait_cost[0:4];
  integer    wait_max [0:4];
  // The AUTHENTIC price of every entry, independent of +ARTIC_BOOST: id1/id2/id4
  // request `cx` units of 0x5E (one unit = 256 ARTIC ticks) and id3 requests `bx`
  // ticks of the 16-bit 0x5C view. One ARTIC tick is 50e6/307200 = 162.76 clk_sys,
  // so the ticks below x 162.76 is what the wait would cost unaccelerated - the one
  // number a boosted run cannot give.
  longint    wait_ticks[0:4];
  integer    wait_big     = 0;   // id=1 entries whose cx is the 4,840-unit settle
  // id=3's request is BX, and the four `call far 0xF760:0x1811` sites in BANK7 pass
  // exactly four values (0xFF195 -> 0x3386, 0xFF1A0 -> 0xCD, 0xFF9B1 -> 0xCC3, and
  // the 10x loop at 0xFFCCF -> 0x77D3). Counting by request says WHICH site the boot
  // is hammering without having to resolve the call site through the z486 pc.
  integer    wait_bx_3386 = 0, wait_bx_cd = 0, wait_bx_cc3 = 0, wait_bx_77d3 = 0;
  integer    wait_bx_other = 0;
  // The pc a few cycles back: z486 can hold pc_now across a multi-cycle far call, so
  // pc_last is not always the call site. pc_d4 is the address four cycles before the
  // entry and names the real `call far` for the first logged entries.
  reg [31:0] pc_d1 = 0, pc_d2 = 0, pc_d3 = 0, pc_d4 = 0, pc_d5 = 0, pc_d6 = 0;
  integer    wait_log     = 0;
  // FDDLOOP: the floppy pass counted by the probe pcs, with the FDD work
  // area it reads. `0xFF6CC` issues the four RECALIBRATEs, `0xFF6D5`/`0xFF701`/`0xFF709`
  // are the probe and its two `[0x55E]` polls, `0xFF194` the readiness ARTIC wait, and
  // `0xFFDCA` the SENSE DRIVE STATUS read helper. A boot whose probe resolves runs the
  // first five twice and then hammers `0xFFDCA` (the media check); one whose probe marks
  // no unit present stops at the second pass. Bounded at 200 entries.
  integer    probe_n      = 0;
  reg [31:0] probe_last = 0;
  always @(posedge clk_sys) begin
    if (pc_now != probe_last) begin
      probe_last <= pc_now;
      if (((pc_now == 32'h000F_F6D5) || (pc_now == 32'h000F_F6CC) ||
           (pc_now == 32'h000F_F701) || (pc_now == 32'h000F_F709) ||
           (pc_now == 32'h000F_F194) || (pc_now == 32'h000F_FDCA)) && (probe_n < 200)) begin
        probe_n = probe_n + 1;
        $display("FDDLOOP #%0d cyc=%0d pc=%08x wa55E=%02x wa55F=%02x wa500=%04x wa480=%02x wa5ae=%02x wa5d7=%02x wa495=%02x",
                 probe_n, tb_cycle, pc_now, ram_byte(32'h0000_055E),
                 ram_byte(32'h0000_055F), ram[32'h0000_0500 >> 2][15:0],
                 ram_byte(32'h0000_0480), ram_byte(32'h0000_05AE),
                 ram_byte(32'h0000_05D7), ram_byte(32'h0000_0495));
      end
    end
  end
  initial begin
    for (integer k = 0; k <= 4; k = k + 1) begin
      wait_cnt[k] = 0;
      wait_cost[k] = 0;
      wait_max[k] = 0;
      wait_ticks[k] = 0;
    end
  end
  always @(posedge clk_sys) begin
    reg [2:0] wid;
    pc_d1 <= pc_now; pc_d2 <= pc_d1; pc_d3 <= pc_d2;
    pc_d4 <= pc_d3; pc_d5 <= pc_d4; pc_d6 <= pc_d5;
    wid = artic_wait_id(pc_now);
    if (wid != wait_id_prev) begin
      if (wait_id_prev != 3'd0) begin
        wait_cost[wait_id_prev] = wait_cost[wait_id_prev] + (tb_cycle - wait_t0);
        if ((tb_cycle - wait_t0) > wait_max[wait_id_prev])
          wait_max[wait_id_prev] = tb_cycle - wait_t0;
      end
      if (wid != 3'd0) begin
        wait_n            = wait_n + 1;
        wait_cnt[wid]     = wait_cnt[wid] + 1;
        wait_t0           = tb_cycle;
        // the request, out of the CPU's own register file (see the note above)
        if (wid == 3'd3) wait_ticks[wid] = wait_ticks[wid] + longint'(dut.cpu.data_unit_inst.ebx[15:0]);
        else             wait_ticks[wid] = wait_ticks[wid] + (longint'(dut.cpu.data_unit_inst.ecx[15:0]) * 64'd256);
        if ((wid == 3'd1) && (dut.cpu.data_unit_inst.ecx[15:0] == 16'h12E8))
          wait_big = wait_big + 1;
        if (wid == 3'd3)
          case (dut.cpu.data_unit_inst.ebx[15:0])
            16'h3386: wait_bx_3386 = wait_bx_3386 + 1;
            16'h00CD: wait_bx_cd = wait_bx_cd + 1;
            16'h0CC3: wait_bx_cc3 = wait_bx_cc3 + 1;
            16'h77D3: wait_bx_77d3 = wait_bx_77d3 + 1;
            default:  wait_bx_other = wait_bx_other + 1;
          endcase
        if (wait_log < 60) begin
          wait_log = wait_log + 1;
          $display("IDEWAIT #%0d id=%0d cyc=%0d pc=%08x caller=%08x pre4=%08x cx=%04x bx=%04x artic=%06x",
                   wait_n, wid, tb_cycle, pc_now, pc_last, pc_d4,
                   dut.cpu.data_unit_inst.ecx[15:0], dut.cpu.data_unit_inst.ebx[15:0],
                   dut.iobus.artic_cnt[23:0]);
        end
      end
      wait_id_prev <= wid;
    end
  end

  // --- the SIM-ONLY ARTIC-unit override ------------------------------
  // The option ROM's wait (BANK3@0x8B16) polls port 0x5E = the ARTIC
  // counter's bits 15:8, so one "unit" is 256 ticks = 41,700 clk_sys cycles and the pacing
  // call at 0x8222 asks for 0x79*(0x28-[es:0x2060]) = 4,840 units = 202 M cycles. An earlier run
  // read that as the first step of a 4.1e9-cycle ladder; measured, the routine is entered
  // six times in the whole boot and that reading does not hold - but one
  // 202 M-cycle wait is already more than this tier's budget, which is why the wedge has
  // looked like a hang.
  //
  // This hook FORCES THE COUNTER FORWARD for exactly as long as the guest is inside one
  // of the ARTIC wait routines `artic_wait_id` names. The guest still observes the same
  // elapsed ARTIC time (the counter ends
  // at the same value it would reach unaided), the ROM's control flow is untouched, and
  // OUTSIDE those windows the counter keeps its exact 307200 Hz rate, so no other firmware
  // timeout moves. The window was extended to the MAIN BIOS's copy of the
  // delay (window offset 0xE11 = linear 0xF8E11, reached only after the FDD probe starts
  // completing): without it the boot advances past the FDD poll and then spends every
  // retry in that copy at the authentic rate. It was widened
  // it once more to EVERY ARTIC wait routine `artic_wait_id` names (the BANK6 copy at
  // 0xF5B62 and the two BANK7 loops at 0xF8E12 / 0xFEE42 as well), because a full boot
  // past the IPL meets waits this tier had never walked; the ENTRY COUNT is the
  // measurement and it is unaffected by the widening. It is a BENCH hook: no RTL changes,
  // no synthesis effect, and OFF unless the run passes +ARTIC_BOOST=<units of 0x5E per
  // cycle> (1 is ample).
  integer    artic_boost    = 0;
  // +BOOST_UNTIL=<cycle>: both boosts (ARTIC and VSYNC) end at that cycle, so the firmware's
  // waits run fast and the guest code after it runs at the authentic rates. 0 = never end.
  longint unsigned boost_until = 0;
  initial void'($value$plusargs("BOOST_UNTIL=%d", boost_until));
  wire boost_live = (boost_until == 0) || (tb_cycle < boost_until);
  integer    artic_boost_n  = 0;
  reg        artic_forced   = 1'b0;
  always @(posedge clk_sys) begin
    if ((artic_boost != 0) && boost_live && (artic_wait_id(pc_now) != 3'd0)) begin
      force dut.iobus.artic_cnt = dut.iobus.artic_cnt + (32'(artic_boost) * 32'd256);
      if (!artic_forced) begin
        artic_forced <= 1'b1;
        if (artic_boost_n < 8)
          $display("ARTIC BOOST on  cyc=%0d pc=%08x artic=%06x", tb_cycle, pc_now,
                   dut.iobus.artic_cnt[23:0]);
        artic_boost_n = artic_boost_n + 1;
      end
    end else if (artic_forced) begin
      release dut.iobus.artic_cnt;
      artic_forced <= 1'b0;
      if (artic_boost_n <= 8)
        $display("ARTIC BOOST off cyc=%0d pc=%08x artic=%06x", tb_cycle, pc_now,
                 dut.iobus.artic_cnt[23:0]);
    end
  end

  // --- VSYNC_BOOST, the text-GDC analogue of ARTIC_BOOST ------------
  // The boot's text-output path synchronises to the text-GDC vsync once per character
  // printed and once per IDE-sector gate, i.e. one 440-line frame each time. At the
  // authentic rate that is ~373k clk_vid cycles per sync, which is why the DOS disk
  // read (many sectors x many characters) exhausts any sane sim budget before
  // CONFIG.SYS/EMM386 is reached. +VSYNC_BOOST=<lines per clk_sys> forces the GDC's
  // vsync status bit so each sync completes in a handful of cycles, the exact
  // analogue of +ARTIC_BOOST. It is a BENCH hook: no RTL change, no synthesis effect,
  // OFF unless the run passes +VSYNC_BOOST. Forcing the status bit (not vline) keeps the
  // scanout and its SDRAM fetch at the authentic rate.
  integer    vsync_boost   = 0;
  reg        vsync_forced  = 1'b0;
  always @(posedge clk_sys) begin
    if ((vsync_boost != 0) && boost_live) begin
      // Toggle the firmware-visible vsync status bit (bit 5 of the 0x60 read) instead
      // of forcing vline: forcing vline floods the scanout's per-line SDRAM fetch and
      // starves the CPU. The toggle is tb_cycle[9] (512 clk_sys), so each BIOS vsync
      // synchronisation completes in a few hundred cycles instead of one 440-line frame.
      force dut.u_crtc.vs_sync_ff = {tb_cycle[9], tb_cycle[8]};
      if (!vsync_forced) begin
        vsync_forced <= 1'b1;
        $display("VSYNC BOOST on  cyc=%0d pc=%08x vs=%b", tb_cycle, pc_now,
                 dut.u_crtc.vs_sync_ff);
      end
    end else if (vsync_forced) begin
      release dut.u_crtc.vs_sync_ff;
      vsync_forced <= 1'b0;
      $display("VSYNC BOOST off cyc=%0d vs=%b", tb_cycle, dut.u_crtc.vs_sync_ff);
    end
  end

  // --- the option ROM's own decision sites ----------------------------
  // An earlier run named three candidate failing steps and could not tell them apart. Each
  // is one comparison in BANK3, so each is watched with the values it compares, from the
  // bench's own SDRAM model and the ATA model's registers (i.e. what the ROM's `in` will
  // read). Site addresses are file offsets of BANK3.BIN + 0xD8000:
  //   0x8286 the 4-pair probe, 0x833B the IDP+recalibrate unit, 0x8557 the RECALIBRATE
  //   handler, 0x8590 the read path's settle, 0x81F3 the settle routine (E1 + CHECK POWER
  //   MODE), 0x8D39 the presence/signature poll, 0x9132 the soft reset, 0x8611 the error
  //   return (AH=0x90), 0x8890 the per-device IPL attempt, 0x8D40/0x9151/0x90C3 the polls.
  integer idestep_n = 0;
  reg [31:0] idestep_last = 32'hFFFF_FFFF;
  localparam integer IDESTEP_MAX = 240;
  always @(posedge clk_sys) begin
    // One line per VISIT, not per cycle: z486 holds the same pc for the whole of a
    // multi-cycle instruction, and the sites below are single instructions.
    idestep_last <= pc_now;
    if ((idestep_n < IDESTEP_MAX) && (pc_now != idestep_last)) begin
      case (pc_now)
        32'h000D_8286: begin
          idestep_n = idestep_n + 1;
          $display("IDESTEP pairprobe      cyc=%0d ram481=%02x ram5ba=%02x ram5bb=%02x", tb_cycle,
                   ram_byte(32'h0000_0481), ram_byte(32'h0000_05BA), ram_byte(32'h0000_05BB));
        end
        32'h000D_833B: begin
          idestep_n = idestep_n + 1;
          $display("IDESTEP driveinit      cyc=%0d caller=%08x rc=%04x result=%04x secA=%02x", tb_cycle,
                   pc_last, ram[32'h000D_A060 >> 2][15:0], ram[32'h000D_A00C >> 2][15:0],
                   ram_byte(32'h000D_A00A));
        end
        32'h000D_8557: begin
          idestep_n = idestep_n + 1;
          $display("IDESTEP recalibrate    cyc=%0d caller=%08x rc=%04x", tb_cycle, pc_last,
                   ram[32'h000D_A060 >> 2][15:0]);
        end
        32'h000D_8590: begin
          idestep_n = idestep_n + 1;
          $display("IDESTEP read-settle    cyc=%0d caller=%08x rc=%04x", tb_cycle, pc_last,
                   ram[32'h000D_A060 >> 2][15:0]);
        end
        32'h000D_820B: begin
          idestep_n = idestep_n + 1;
          $display("IDESTEP settle-wait    cyc=%0d rc=%04x result=%04x secA=%02x", tb_cycle,
                   ram[32'h000D_A060 >> 2][15:0], ram[32'h000D_A00C >> 2][15:0],
                   ram_byte(32'h000D_A00A));
        end
        32'h000D_823E: begin
          idestep_n = idestep_n + 1;
          $display("IDESTEP pwr-mode      cyc=%0d secA=%02x latch=%04x acc62=%04x ata_st=%02x err=%02x",
                   tb_cycle, ram_byte(32'h000D_A00A), ram[32'h000D_A010 >> 2][15:0],
                   ram[32'h000D_A062 >> 2][15:0], dut.ata.status_reg, dut.ata.error_reg);
        end
        32'h000D_8269: begin
          idestep_n = idestep_n + 1;
          $display("IDESTEP pwr-mode FAIL cyc=%0d secA=%02x" , tb_cycle, ram_byte(32'h000D_A00A));
        end
        32'h000D_826C: begin
          idestep_n = idestep_n + 1;
          $display("IDESTEP pwr-mode ok   cyc=%0d secA=%02x", tb_cycle, ram_byte(32'h000D_A00A));
        end
        32'h000D_8D39: begin
          idestep_n = idestep_n + 1;
          $display("IDESTEP presence poll cyc=%0d ata=err%02x st%02x cnt%02x num%02x cyl%02x/%02x dh%02x rec=%02x",
                   tb_cycle, dut.ata.error_reg, dut.ata.status_reg, dut.ata.sector_count,
                   dut.ata.sector_number, dut.ata.cylinder_high, dut.ata.cylinder_low,
                   dut.ata.drive_head, ram[32'h000D_A060 >> 2][7:0]);
        end
        32'h000D_8D76: begin
          idestep_n = idestep_n + 1;
          $display("IDESTEP sig want1     cyc=%0d ata_err=%02x ata_st=%02x ram642=%02x", tb_cycle,
                   dut.ata.error_reg, dut.ata.status_reg, ram_byte(32'h0000_0642));
        end
        32'h000D_8DA2: begin
          idestep_n = idestep_n + 1;
          $display("IDESTEP presence FAIL cyc=%0d ata_err=%02x ata_st=%02x", tb_cycle,
                   dut.ata.error_reg, dut.ata.status_reg);
        end
        32'h000D_8DA5: begin
          idestep_n = idestep_n + 1;
          $display("IDESTEP presence ok   cyc=%0d ata_err=%02x ata_st=%02x", tb_cycle,
                   dut.ata.error_reg, dut.ata.status_reg);
        end
        32'h000D_9132: begin
          idestep_n = idestep_n + 1;
          $display("IDESTEP SRST          cyc=%0d caller=%08x ata=err%02x st%02x cnt%02x num%02x cyl%02x/%02x",
                   tb_cycle, pc_last, dut.ata.error_reg, dut.ata.status_reg,
                   dut.ata.sector_count, dut.ata.sector_number, dut.ata.cylinder_high,
                   dut.ata.cylinder_low);
        end
        32'h000D_919B: begin
          idestep_n = idestep_n + 1;
          $display("IDESTEP SRST FAIL     cyc=%0d ata_err=%02x ata_st=%02x", tb_cycle,
                   dut.ata.error_reg, dut.ata.status_reg);
        end
        32'h000D_919E: begin
          idestep_n = idestep_n + 1;
          $display("IDESTEP SRST ok       cyc=%0d ata_err=%02x ata_st=%02x", tb_cycle,
                   dut.ata.error_reg, dut.ata.status_reg);
        end
        32'h000D_90F8: begin
          idestep_n = idestep_n + 1;
          $display("IDESTEP DRDY poll FAIL cyc=%0d ata_st=%02x err=%02x ram642=%02x", tb_cycle,
                   dut.ata.status_reg, dut.ata.error_reg, ram_byte(32'h0000_0642));
        end
        32'h000D_90FF: begin
          idestep_n = idestep_n + 1;
          $display("IDESTEP DRDY poll ok   cyc=%0d ata_st=%02x err=%02x", tb_cycle,
                   dut.ata.status_reg, dut.ata.error_reg);
        end
        32'h000D_8611: begin
          idestep_n = idestep_n + 1;
          $display("IDESTEP error ret 0x90 cyc=%0d result=%04x caller=%08x", tb_cycle,
                   ram[32'h000D_A00C >> 2][15:0], pc_last);
        end
        32'h000D_8890: begin
          idestep_n = idestep_n + 1;
          $display("IDESTEP IPL attempt    cyc=%0d rc=%04x secA=%02x", tb_cycle,
                   ram[32'h000D_A060 >> 2][15:0], ram_byte(32'h000D_A00A));
        end
        default: ;
      endcase
    end
  end

  // --- the option ROM's task-file traffic -----------------------------
  // Bounded by construction: one line per (pc, port) the FIRST time it is seen and
  // thereafter only when the byte CHANGES, which is what turns a 2.5e6-iteration poll
  // into one line carrying the value it spun on. `n=` is that site's access count, so
  // the spin length is readable from the same line. Ports 0x0640-0x064F are the task
  // file and 0x074C the soft-reset control register (BANK3@0x9132).
  localparam integer TF_MAX  = 96;
  localparam integer TF_LINE = 400;
  reg [31:0] tf_pc   [0:TF_MAX-1];
  reg [15:0] tf_port [0:TF_MAX-1];
  reg [7:0]  tf_val  [0:TF_MAX-1];
  integer    tf_cnt  [0:TF_MAX-1];
  integer    tf_n = 0;
  integer    tf_lines = 0;
  always @(posedge clk_sys) begin
    integer k, slot;
    reg [7:0] v;
    if ((dut.iobus.state == pc9821_ports_pkg::S_BYTE) &&
        (((dut.iobus.port_addr >= 16'h0640) && (dut.iobus.port_addr <= 16'h064F)) ||
         (dut.iobus.port_addr == 16'h074C))) begin
      slot = -1;
      for (k = 0; k < tf_n; k = k + 1)
        if ((tf_pc[k] == pc_now) && (tf_port[k] == dut.iobus.port_addr)) slot = k;
      if ((slot < 0) && (tf_n < TF_MAX)) begin
        slot = tf_n;
        tf_n = tf_n + 1;
        tf_pc[slot] = pc_now;
        tf_port[slot] = dut.iobus.port_addr;
        tf_val[slot] = 8'hxx;
        tf_cnt[slot] = 0;
      end
      if (slot >= 0) begin
        v = dut.iobus.request_write ? dut.iobus.device_io_din : dut.iobus.lane_rdata;
        tf_cnt[slot] = tf_cnt[slot] + 1;
        if (v !== tf_val[slot]) begin
          tf_val[slot] = v;
          if (tf_lines < TF_LINE) begin
            tf_lines = tf_lines + 1;
            $display("IDETASK cyc=%0d %s port=%04x val=%02x pc=%08x n=%0d", tb_cycle,
                     dut.iobus.request_write ? "wr" : "rd", dut.iobus.port_addr, v, pc_now,
                     tf_cnt[slot]);
          end
        end
      end
    end
  end

  // --- FDCTRACE: every access the BIOS makes to the FDC trio ----------
  // Ports 0x90 (main status), 0x92 (data) and 0x94 (DOR/CCR) are decoded as
  // SYSTEM ports, so they never reach device_io and the IO HISTORY ring above
  // cannot see them. The BIOS's FDD path is the only code that touches them, and
  // this instrument logs the whole conversation so the minimal model can be
  // derived from it rather than guessed: the command byte written to 0x92, each
  // parameter, and what the probe reads back on 0x90/0x92. Bounded: the trace
  // stops after FDCTRACE_MAX lines; a status RQM poll collapses into a repeat
  // count so the command/result bytes stay readable in the middle of it.
  localparam integer FDCTRACE_MAX = 1200;
  integer    fdc_n = 0;
  reg [15:0] fdc_port = 16'hFFFF;
  reg        fdc_last_wr = 1'b0;
  reg [7:0]  fdc_last_val = 8'hxx;
  integer    fdc_rep = 0;
  always @(posedge clk_sys) begin
    if (dut.iobus.state == pc9821_ports_pkg::S_BYTE) begin
      if ((dut.iobus.port_addr == 16'h0090) ||
          (dut.iobus.port_addr == 16'h0092) ||
          (dut.iobus.port_addr == 16'h0094)) begin
        reg [7:0] b;
        b = dut.iobus.request_write ? dut.iobus.lane_wdata : dut.iobus.lane_rdata;
        if ((dut.iobus.port_addr == fdc_port) &&
            (dut.iobus.request_write == fdc_last_wr) && (b == fdc_last_val)) begin
          fdc_rep = fdc_rep + 1;
        end else begin
          if ((fdc_n < FDCTRACE_MAX) && (fdc_rep > 1))
            $display("FDCTRACE cyc=%0d (previous access repeated %0d more times)", tb_cycle,
                     fdc_rep - 1);
          fdc_n = fdc_n + 1;
          fdc_port = dut.iobus.port_addr;
          fdc_last_wr = dut.iobus.request_write;
          fdc_last_val = b;
          fdc_rep = 1;
          if (fdc_n <= FDCTRACE_MAX)
            $display("FDCTRACE cyc=%0d %s port=%04x data=%02x pc=%08x fdc=%b irq=%b st=%0d", tb_cycle,
                     dut.iobus.request_write ? "wr" : "rd", dut.iobus.port_addr, b, pc_now,
                     dut.iobus.fdc.pend, dut.iobus.fdc.irq, dut.iobus.fdc.st);
        end
      end
    end
  end

  // --- FDCCMD: only the command/parameter bytes the BIOS writes to 0x92 ------
  // FDCTRACE above can exhaust its budget in the status polls; this one logs just
  // the writes (the command byte and each parameter) with the model's own state,
  // so the whole conversation is readable even when the run is long.
  localparam integer FDCCMD_MAX = 400;
  integer fdc_cmd_n = 0;
  always @(posedge clk_sys) begin
    if ((dut.iobus.state == pc9821_ports_pkg::S_BYTE) && (dut.iobus.port_addr == 16'h0092) &&
        dut.iobus.request_write) begin
      fdc_cmd_n = fdc_cmd_n + 1;
      if (fdc_cmd_n <= FDCCMD_MAX)
        $display("FDCCMD cyc=%0d wr data=%02x pc=%08x fdc=%b irq=%b st=%0d", tb_cycle,
                 dut.iobus.lane_wdata, pc_now, dut.iobus.fdc.pend, dut.iobus.fdc.irq,
                 dut.iobus.fdc.st);
    end
  end

  // --- is the guest PROGRESSING, and what does it spin on -------------
  // Once the ARTIC wait is walked the run reaches code earlier runs never saw, so two more
  // instruments are needed. Both are bounded. PROGRESS prints the retired-instruction
  // count per interval, which separates "running slowly" from "wedged": a wedge moves
  // the PC a few times a second, a slow loop thousands. IDEPOLL watches the one poll the
  // guest actually sits in (BANK7@0xFF23F: `mov al,[bx]` with an I/O-wait per iteration,
  // comparing [bx] & AH against AH and retrying DH=0x60 times) and prints the byte it
  // reads, recomputed from DS:BX because the poll's repeated read HITS IN THE D-CACHE
  // and so never appears on the CPU bus. The address is the LINEAR pc: BANK7 offset
  // 0x7245 runs in the FD80 segment as IP 0x1A45, i.e. 0xF8000 + 0x7245 = 0xFF245.
  // n= counts the cycles spent in the poll's five instructions, so consecutive lines
  // give one outer retry's cost directly (measured: 6,094,856).
  localparam integer PROG_DIV = 2_000_000;
  integer      prog_tick = 0;
  integer      prog_n    = 0;
  reg [31:0]   prog_pc_idx = 32'd0;
  integer      idepoll_n = 0;
  integer      idepoll_lines = 0;
  reg          ivt13_dumped = 1'b0;
  reg [31:0]   idepoll_addr = 32'hFFFF_FFFF;
  reg [7:0]    idepoll_val  = 8'h00;
  reg [7:0]    idepoll_dh   = 8'hFF;
  always @(posedge clk_sys) begin
    if (handoff_seen) begin
      if (prog_tick >= PROG_DIV - 1) begin
        prog_tick = 0;
        if (prog_n < 200) begin
          prog_n = prog_n + 1;
          $display("PROGRESS cyc=%0d pc=%08x retired=%0d per=%0dk cs=%04x eip=%08x top_bank=%0d artic=%06x ram55E=%02x ram642=%02x",
                   tb_cycle, pc_now, pc_idx - prog_pc_idx, PROG_DIV / 1000, cpu_cs, cpu_eip,
                   dut.iobus.top_bank, dut.iobus.artic_cnt[23:0],
                   ram_byte(32'h0000_055E), ram_byte(32'h0000_0642));
        end
        prog_pc_idx = pc_idx;
      end else begin
        prog_tick = prog_tick + 1;
      end
    end
    if ((pc_now >= 32'h000F_F243) && (pc_now <= 32'h000F_F251)) begin
      reg [31:0] pa;
      pa = dut.cpu.seg_unit.desc_cache[3].base + {16'd0, dut.cpu.data_unit_inst.ebx[15:0]};
      idepoll_n = idepoll_n + 1;
      // IVT13: the byte the poll waits for (work-area 0x55E, low nibble 0x0F) is set by
      // the FDD ISR at physical 0xF8000+0x7AF7 (`or [es:0x55e],ah` at 0x7B53). The FDC's
      // IRQ11 vectors to IVT 0x13, so the handler actually installed there decides whether
      // the poll can ever pass. Printed once, when the poll is entered.
      if (!ivt13_dumped) begin
        ivt13_dumped = 1'b1;
        $display("IDEPOLL IVT 0x13 = %04x:%04x (handler phys %08x) at cyc=%0d",
                 ram[32'h0000_004C >> 2][31:16], ram[32'h0000_004C >> 2][15:0],
                 ({16'd0, ram[32'h0000_004C >> 2][31:16]} << 4) +
                 {16'd0, ram[32'h0000_004C >> 2][15:0]}, tb_cycle);
      end
      if (((pa != idepoll_addr) || (ram_byte(pa) != idepoll_val) ||
           (dut.cpu.data_unit_inst.edx[15:8] != idepoll_dh)) && (idepoll_lines < 32)) begin
        idepoll_lines = idepoll_lines + 1;
        idepoll_addr = pa;
        idepoll_val  = ram_byte(pa);
        idepoll_dh   = dut.cpu.data_unit_inst.edx[15:8];
        $display("IDEPOLL cyc=%0d pc=%08x ds=%08x bx=%04x want=%02x have=%02x retries_left=%02x n=%0d",
                 tb_cycle, pc_now, dut.cpu.seg_unit.desc_cache[3].base,
                 dut.cpu.data_unit_inst.ebx[15:0], dut.cpu.data_unit_inst.eax[15:8],
                 ram_byte(pa), dut.cpu.data_unit_inst.edx[15:8], idepoll_n);
      end
    end
  end

  // --- the INT 1Ch calendar caller, and the 48 bits it is served ---------------
  // WHY: the EMM386-profile boot (a minimal EMM386 boot image)
  // spends tens of millions of cycles inside the Xe10 BIOS's INT 1Ch AH=0 calendar
  // read - FD80:0500 (BANK7, pack +0x20000 at the 0xF8000 window) trampolining to the
  // F660 prologue and back to FD80:050A - and then leaves it. The PC rings name the
  // CALLEE only (`in al,0x33`, `out 0x20`, the 3 x `out 0x5F` helper at 0xFD63D), so
  // the loop AROUND the handler is invisible. This names it, in three parts, all off
  // unless +CAL_TRACE=<cycle> arms them at that cycle:
  //   CAL CALLER  every entry to the vector target 0xFD500, with the pc that entered
  //               and the four cycles before it (z486 can hold pc_now across a
  //               multi-cycle transfer, so pc_last is not always the site), deduped;
  //   CAL BITS    the bits the GUEST's own reader assembles: BANK7@0x5D3D reads bit 0
  //               of 0x33, `shr al,1` / `rcr ah,1`, so the FIRST bit read is bit 0 of
  //               the byte and 48 reads make the six bytes at es:[bx+5..bx+0];
  //   CAL BUFRAM  that destination (ES:BX, as the caller set it) plus the byte beside it,
  //               read out of guest RAM at the end: the six clock bytes the caller holds and
  //               DS:03F7, the retry delay it waits out.
  // The wire value and the model's own cdat are printed side by side: a mismatch is an
  // integration defect (iobus 0x33 arm), not a calendar one.
  // +CAL_TRACE=<cycle> arms the trace AT THAT CYCLE; the default -1 is OFF, which has to
  // be the initial value: arming on `tb_cycle >= cal_trace_at` with the usual 0 default
  // armed it at cycle 0, before the plusargs are even parsed (the pack load takes ~6.6 M
  // cycles), and the rings then held the reset vectors' pcs instead of the loop's.
  integer      cal_trace_at  = -1;
  reg          cal_trace_en  = 1'b0;
  integer      cal_entry_n   = 0;
  // The 48-bit read: cal_bits[i] is the i-th bit the guest clocked in, so byte k is
  // cal_bits[8k +: 8] after the reader's own MSB-first assembly (bit 0 first = LSB of
  // the byte). A group is 48+ consecutive 0x33 reads; the gap test separates reads.
  reg [47:0]   cal_bits      = 48'h0;
  integer      cal_bitn      = 0;
  integer      cal_group_n   = 0;
  integer      cal_group_shown = 0;
  reg [63:0]   cal_rd_cyc    = 64'd0;
  // The caller's buffer, as of the last entry.
  reg [31:0]   cal_es        = 32'h0;
  reg [15:0]   cal_bx        = 16'h0;
  reg [7:0]    cal_lane      = 8'h00;   // what the CPU was served at 0x33
  reg [7:0]    cal_cdat_see  = 8'h00;   // the calendar's own cdat at the same strobe
  reg [15:0]   cal_rd_port   = 16'h0;   // the address the fabric presented for that read
  integer      cal_wire_bad  = 0;
  // The caller's own loop: every distinct pc OUTSIDE the handler's window, so the
  // ~10 instructions per ~24k-cycle callee are no longer crowded out of pc_hist.
  // A ROLLING ring (the last CAL_PC_N distinct), not a first-fill one: the first-fill
  // version filled with the ITF's resets and stopped, which is how it read as "the
  // caller" while the callee's window was never even entered.
  localparam integer CAL_PC_N = 32;
  reg [31:0]   cal_pc        [0:CAL_PC_N-1];
  integer      cal_pc_idx    = 0;
  integer      cal_pc_hit    = 0;
  // THE RETURN ADDRESS ON THE STACK is the caller, exactly: `int 1Ch` pushes FLAGS, CS
  // and IP, so [SS:SP] is the instruction after the `int` and [SS:SP+2] its CS. pc_last
  // is only a hint (z486 can hold pc_now across a multi-cycle transfer), and the register
  // pair ES:BX names the caller's buffer but not its code. SS's descriptor base is slot 2
  // in z486's seg_unit (ES 0, CS 1, SS 2, DS 3).
  localparam integer CAL_RET_N = 8;
  reg [31:0]   cal_ret       [0:CAL_RET_N-1];
  integer      cal_ret_n     = 0;
  integer      cal_ret_cnt   [0:CAL_RET_N-1];
  integer      cal_gap_min   = 0;
  integer      cal_gap_max   = 0;
  longint      cal_gap_sum   = 0;
  integer      cal_gap_n     = 0;
  reg [63:0]   cal_prev_cyc  = 64'd0;
  always @(posedge clk_sys) begin
    integer i, seen;
    if (!cal_trace_en && (cal_trace_at >= 0) && (tb_cycle >= cal_trace_at)) cal_trace_en <= 1'b1;
    if (cal_trace_en) begin
      if (pc_now != pc_last) begin
        // The callee: FD80's base is 0xFD800, so the handler body (EIP 0x50A-0x5B6) is
        // 0xFDD0A-0xFDD56 and the delay helper (EIP 0x63D) is 0xFDE3D. The entry vector
        // FD80:0500 is therefore 0xFDD00 - NOT 0xFD500, which is what a first version of
        // this instrument tested for and never matched.
        if (!(pc_now >= 32'h000F_D800 && pc_now <= 32'h000F_DEFF)) begin
          cal_pc[cal_pc_idx % CAL_PC_N] = pc_now;
          cal_pc_idx = cal_pc_idx + 1;
          cal_pc_hit = cal_pc_hit + 1;
        end
      end
      if ((pc_now == 32'h000F_DD00) && (pc_now != pc_last)) begin
        // THE CALLER, from the stack: `int 1Ch` pushes FLAGS, CS and IP, so [SS:SP] is
        // the instruction after the `int` and [SS:SP+2] its CS. This is exact where pc_last
        // is only a hint (z486 can hold pc_now across a multi-cycle transfer) and where the
        // caller's ES:BX names its buffer but not its code. SS's descriptor base is slot 2
        // in z486's seg_unit (ES 0, CS 1, SS 2, DS 3).
        reg [31:0] ssb, ret_pc;
        reg [15:0] sp;
        reg [31:0] gap;
        ssb = dut.cpu.seg_unit.desc_cache[2].base;
        sp  = dut.cpu.data_unit_inst.esp[15:0];
        ret_pc = ({16'd0, ram[((ssb + sp + 32'd2) >> 2)][15:0]} << 4) +
                 {16'd0, ram[((ssb + sp) >> 2)][15:0]};
        seen = -1;
        for (i = 0; i < cal_ret_n; i = i + 1)
          if (cal_ret[i] == ret_pc) seen = i;
        if (seen >= 0) cal_ret_cnt[seen] = cal_ret_cnt[seen] + 1;
        else if (cal_ret_n < CAL_RET_N) begin
          cal_ret[cal_ret_n]     = ret_pc;
          cal_ret_cnt[cal_ret_n] = 1;
          cal_ret_n = cal_ret_n + 1;
        end
        cal_entry_n = cal_entry_n + 1;
        if (cal_prev_cyc != 64'd0) begin
          gap = 32'(tb_cycle - cal_prev_cyc);
          if ((cal_gap_n == 0) || (32'(gap) < cal_gap_min)) cal_gap_min = 32'(gap);
          if (32'(gap) > cal_gap_max) cal_gap_max = 32'(gap);
          cal_gap_sum = cal_gap_sum + longint'(gap);
          cal_gap_n   = cal_gap_n + 1;
        end
        cal_prev_cyc = tb_cycle;
        // ES is descriptor slot 0 in z486's seg_unit (DS is slot 3, as the IDEPOLL
        // probe above reads it); the buffer the AH=0 path stores into is es:[bx+si].
        cal_es = dut.cpu.seg_unit.desc_cache[0].base;
        cal_bx = dut.cpu.data_unit_inst.ebx[15:0];
      end
      // The calendar read is the only port traffic inside the handler's window, and the
      // ADDRESS the fabric presents is not reliable for it: the integrated tier's own IO
      // RING records these reads as `r0000` while the firmware's `in al,0x33` (BANK7@0x5D3D)
      // asks for 0x33, so triggering on the port would miss the read entirely. The pc is
      // unambiguous (the guest is blocked ON the `in` until the access completes).
      if (dut.device_io_rd && (pc_now >= 32'h000F_D800) && (pc_now <= 32'h000F_DEFF)) begin
        // A new group starts when this read is far enough from the last one: per bit the
        // reader spends ~200 cycles (two `out 0x20` at the floor plus six `out 0x5F` at
        // 0xFD63D), so 400 cleanly separates one 48-bit read from the next.
        if ((tb_cycle - cal_rd_cyc) > 64'd400 && cal_bitn != 0) begin
          if (cal_bitn >= 40) begin
            cal_group_n = cal_group_n + 1;
            if (cal_group_shown < 4) begin
              cal_group_shown = cal_group_shown + 1;
              $display("CAL BITS #%0d cyc=%0d n=%0d es=%04x bx=%04x sec=%02x min=%02x hour=%02x day=%02x mon=%02x year=%02x | model sec=%02x mon=%02x year=%02x mode=%02x shifting=%0d port=%04x",
                       cal_group_n, tb_cycle, cal_bitn, cal_es[19:4], cal_bx,
                       cal_bits[7:0], cal_bits[15:8], cal_bits[23:16],
                       cal_bits[31:24], cal_bits[39:32], cal_bits[47:40],
                       dut.calendar.c_sec, dut.calendar.c_month, dut.calendar.c_year,
                       dut.calendar.mode_reg, dut.calendar.shifting, cal_rd_port);
            end
          end
          cal_bitn = 0;
          cal_bits = 48'h0;
        end
        cal_rd_cyc   = {32'd0, tb_cycle};
        cal_lane     = dut.iobus.lane_rdata;
        cal_cdat_see = {7'b0, dut.calendar.cdat};
        cal_rd_port  = dut.device_io_addr;
        if (cal_lane[0] !== cal_cdat_see[0]) cal_wire_bad = cal_wire_bad + 1;
        if (cal_bitn < 48) cal_bits[cal_bitn] = cal_lane[0];
        cal_bitn = cal_bitn + 1;
      end
    end
  end

  // --- timed PC sampler -----------------------------------------------------
  // The change-triggered ring above cannot tell a cached self-loop at one
  // address from a CPU stalled inside one instruction: both produce exactly one
  // entry, and both leave the bus idle. Sampling pc_now on a free-running timer
  // instead shows whether the PC moves at all, which is the question the 0x411B
  // stop turns on. The bank is latched alongside each sample because the fetched
  // bytes at a PC depend on which 32 KiB bank the 0xF800 window holds.
  localparam integer PC_SAMP      = 64;
  localparam integer PC_SAMP_DIV  = 1000;
  reg [31:0] pc_samp      [0:PC_SAMP-1];
  reg [3:0]  pc_samp_bank [0:PC_SAMP-1];
  integer    pc_samp_idx  = 0;
  integer    pc_samp_n    = 0;
  integer    pc_samp_clk  = 0;
  always @(posedge clk_sys) begin
    if (pc_samp_clk >= PC_SAMP_DIV - 1) begin
      pc_samp_clk = 0;
      pc_samp[pc_samp_idx]      = pc_now;
      pc_samp_bank[pc_samp_idx] = dut.iobus.top_bank;
      pc_samp_idx = (pc_samp_idx + 1) % PC_SAMP;
      if (pc_samp_n < PC_SAMP) pc_samp_n = pc_samp_n + 1;
    end else begin
      pc_samp_clk = pc_samp_clk + 1;
    end
  end

  // What the CPU actually fetches at the stop. The F800 window is a 32 KiB
  // bank chosen by top_bank, so the byte at linear 0xFC11B is pack byte
  // bank_offset(top_bank) + 0x411B; read it straight out of the downloaded
  // pack so a banked-away window (e.g. a deliberate `EB FE` park) is visible.
  function automatic [31:0] tb_bank_offset(input [3:0] state);
    case (state)
      4'd0: tb_bank_offset = 32'h0003_1000;
      4'd1: tb_bank_offset = 32'h0003_9000;
      4'd2: tb_bank_offset = 32'h0004_1000;
      4'd3: tb_bank_offset = 32'h0007_0000;
      4'd4: tb_bank_offset = 32'h0000_0000;
      4'd5: tb_bank_offset = 32'h0001_0000;
      4'd6: tb_bank_offset = 32'h0001_8000;
      4'd7: tb_bank_offset = 32'h0002_0000;
      4'd8: tb_bank_offset = 32'h0000_0000;
      4'd9: tb_bank_offset = 32'h0002_0000;
      default: tb_bank_offset = 32'h0000_0000;
    endcase
  endfunction

  task automatic dump_pc_samples;
    integer k, p, distinct, j, dup;
    reg [31:0] v;
    reg [31:0] base;
    reg [7:0]  b;
    begin
      distinct = 0;
      for (k = 0; k < pc_samp_n; k = k + 1) begin
        p = (pc_samp_idx - pc_samp_n + k + PC_SAMP*2) % PC_SAMP;
        v = pc_samp[p];
        dup = 0;
        for (j = 0; j < k; j = j + 1)
          if (pc_samp[(pc_samp_idx - pc_samp_n + j + PC_SAMP*2) % PC_SAMP] == v)
            dup = 1;
        if (!dup) distinct = distinct + 1;
      end
      $display("PC SAMPLES (timer, every %0d cycles, at cyc=%0d, oldest first, %0d entries, %0d distinct):",
               PC_SAMP_DIV, tb_cycle, pc_samp_n, distinct);
      for (k = 0; k < pc_samp_n; k = k + 1) begin
        p = (pc_samp_idx - pc_samp_n + k + PC_SAMP*2) % PC_SAMP;
        $write("  %08x/b%0d", pc_samp[p], pc_samp_bank[p]);
        if ((k+1) % 8 == 0) $write("\n");
      end
      $write("\n");
      $display("FETCH WORD top_bank=%0d pack_off=%06x base=%08x",
               dut.iobus.top_bank, tb_bank_offset(dut.iobus.top_bank),
               32'h0200_0000 + tb_bank_offset(dut.iobus.top_bank));
      base = 32'h0200_0000 + tb_bank_offset(dut.iobus.top_bank) + 32'h4110;
      $write("  bytes 0xFC110..0xFC12F:");
      for (k = 0; k < 32; k = k + 1) begin
        if (k % 16 == 0) $write("\n    %05x:", 32'h000FC110 + k);
        b = ram[(base + k) >> 2] >> (((base + k) % 4) * 8);
        $write(" %02x", b);
      end
      $write("\n");
    end
  endtask

  task automatic dump_cal_trace;
    integer i, n;
    begin
      if (!cal_trace_en) begin
        $display("CAL TRACE: off (pass +CAL_TRACE=<cycle> to arm it)");
        return;
      end
      $display("CAL ENTRIES entries=%0d wire_mismatch=%0d groups=%0d (last group n=%0d)",
               cal_entry_n, cal_wire_bad, cal_group_n, cal_bitn);
      for (i = 0; i < cal_ret_n; i = i + 1)
        $display("CAL CALLER ret=%08x hits=%0d bytes=%02x%02x%02x%02x%02x%02x%02x%02x",
                 cal_ret[i], cal_ret_cnt[i],
                 ram_byte(cal_ret[i] - 32'd6), ram_byte(cal_ret[i] - 32'd5),
                 ram_byte(cal_ret[i] - 32'd4), ram_byte(cal_ret[i] - 32'd3),
                 ram_byte(cal_ret[i] - 32'd2), ram_byte(cal_ret[i] - 32'd1),
                 ram_byte(cal_ret[i]), ram_byte(cal_ret[i] + 32'd1));
      if (cal_gap_n != 0)
        $display("CAL CALLER spacing cycles: min=%0d max=%0d mean=%0d over %0d",
                 cal_gap_min, cal_gap_max, cal_gap_sum / cal_gap_n, cal_gap_n);
      // DOS's own clock buffer, at the caller's own ES:BX (the AH=0 path stores the six
      // bytes at es:[bx+5..bx+0], so bx+5 = SECONDS and bx+0 = year), plus the byte beside
      // it: IO.SYS 0xB1B0 compares the elapsed seconds against DS:03F7, so bx+6 is the
      // retry delay the loop is actually waiting out - a whole second at a time.
      $write("CAL BUFRAM %04x:%04x:", cal_es[19:4], cal_bx);
      for (i = 0; i < 8; i = i + 1) $write(" %02x", ram_byte(cal_es + {16'd0, cal_bx} + i));
      $write("\n");
      // The caller's own loop: the last CAL_PC_N distinct pcs OUTSIDE the handler's
      // window, oldest first. ~10 of these per ~24k-cycle callee, so pc_hist never holds
      // them - which is why the caller was invisible until this existed.
      n = (cal_pc_idx < CAL_PC_N) ? cal_pc_idx : CAL_PC_N;
      $display("CAL OUTSIDE distinct=%0d (last %0d, oldest first)", cal_pc_hit, n);
      for (i = 0; i < n; i = i + 1)
        $display("  %08x", cal_pc[(cal_pc_idx - n + i + CAL_PC_N*2) % CAL_PC_N]);
    end
  endtask

  integer pc_seq_n = 48;
  initial if ($value$plusargs("PC_SEQ_N=%d", pc_seq_n) && pc_seq_n > PC_HIST) pc_seq_n = PC_HIST;
  task automatic dump_pc_tail;
    integer i, j, n, dup;
    reg [31:0] v;
    begin
      // The SEQUENCE matters: printing distinct addresses hides whether the
      // guest is looping or has simply stopped, which is the first thing to
      // know about a stall.
      // +PC_SEQ_N=<n> (at most PC_HIST) lengthens it, to reach back past a fault's handler.
      $display("PC SEQUENCE: the last %0d executed (oldest first)", pc_seq_n);
      for (i = pc_seq_n; i >= 1; i = i - 1)
        if (pc_idx >= i)
          $display("  %08x", pc_hist[(pc_idx - i) % PC_HIST]);
      // The CPU-side memory handshake: an outstanding request with ready stuck
      // low is a DROPPED bus request, which is what a stall with an idle I/O
      // bus and no fault looks like.
      // Is the CPU executing at all? With no bus request outstanding, the CPU's own
      // halted flag is the difference between a stalled CPU and a stopped one (the
      // system-level cpu_irq_state this used to read went away with the 2026-10-03
      // CPU rewrite's telemetry).
      $display("TIMEOUT CPUSTATE halted=%0d", dut.cpu.halted);
      // Which stall term holds the pipeline: the CPU is off the bus, so the
      // answer is one of z486's internal stall sources, not a bus wait.
      $display("Z486 STALL stall=%0d mem=%0d wio=%0d fast=%0d x87=%0d invlpg=%0d servicing=%0d busy=%0d req=%0d accepted=%0d uc_active=%0d uc_busreq=%0d",
               dut.cpu.stall, dut.cpu.stall_mem,
               dut.cpu.stall_wio, dut.cpu.stall_fast_store,
               dut.cpu.stall_x87_direct, dut.cpu.stall_invlpg,
               dut.cpu.mem_servicing, dut.cpu.mem_block_busy,
               dut.cpu.mem_req_current, dut.cpu.mem_accepted,
               dut.cpu.uc_active, dut.cpu.uc_busreq);
      $display("TIMEOUT MEMHS cpu_mem_valid=%0d mem_ready=%0d resp_valid=%0d z_valid=%0d z_io=%0d z_addr=%08x line_read=%0d",
               dut.cpu_mem_valid, dut.mem_cpu_ready, dut.mem_cpu_resp_valid,
               dut.z_valid, dut.z_io, {dut.z_addr, 2'b00}, dut.z_line_read);
      // WHERE the accepted request is stuck. mem_valid/mem_ready/mem_resp_valid are the
      // BACKEND handshake (the SDRAM through the clock bridge); the rest is the route queue that
      // decides which route's response this is.
      // gvsel is the GVRAM route's select: the GVRAM array is block RAM now and makes
      // NO backend request, so the route field it replaced no longer exists either (the response's
      // route is the response itself, pc9821_memory_subsystem's route-queue note).
      $display("TIMEOUT MEMROUTE mvalid=%0d mready=%0d mresp=%0d loader=%0d gvsel=%0d mapacc=%0d rt_wr=%0d rt_rd=%0d rt_left=%0d",
               dut.memory.mem_valid, dut.memory.mem_ready, dut.memory.mem_resp_valid,
               dut.memory.loader_owns, dut.memory.gvram_select, dut.memory.map_accepted,
               dut.memory.rt_wr, dut.memory.rt_rd, dut.memory.rt_left);
      $display("TIMEOUT ZCPU mblock_busy=%0d mreq=%0d macc=%0d mserv=%0d icache_state=%0d icache_line=%0d icache_resp=%0d",
               dut.cpu.mem_block_busy, dut.cpu.mem_req_current, dut.cpu.mem_accepted,
               dut.cpu.mem_servicing, dut.cpu.memory_inst.cache_unit_inst.icache_inst.state,
               dut.cpu.memory_inst.cache_unit_inst.icache_inst.fill_line,
               dut.cpu.memory_inst.cache_unit_inst.icache_inst.cpu_resp_valid);
      $display("TIMEOUT MEMREQ mwrite=%0d mburst=%0d owed=%0d rda=%0d bacc=%0d beat=%0d hdone=%0d",
               dut.memory.mem_write, dut.memory.mem_burstcount,
               dut.memory.rt_owed, dut.memory.read_accept, dut.memory.backend_accept,
               dut.memory.resp_beat, dut.memory.head_done);
      $display("TIMEOUT MAPCPU mvalid=%0d mready=%0d map_valid=%0d map_ready=%0d cpu_valid=%0d local=%0d oor=%0d fwblk=%0d",
               dut.memory.mem_valid, dut.memory.mem_ready, dut.memory.map_valid,
               dut.memory.map_ready, dut.memory.mapper.cpu_valid,
               dut.memory.mapper.local_accept, dut.memory.mapper.out_of_range,
               dut.memory.mapper.fw_write_blocked);
      // The PAGING UNIT's own state, which decides whether the stuck write is
      // in PG_MEM_TLB (translated, waiting an accept) or PG_WALKING (its page walk is the stuck
      // access), and why it is non-posting (write_will_post).
      $display("TIMEOUT PGU state=%0d wr=%0d lin=%08x willpost=%0d dlygrace=%0d wrwait=%0d cantr=%0d tlbhit=%0d tlbdirty=%0d dirtyok=%0d livev=%0d liveposts=%0d fastpend=%0d crossing=%0d off=%0d",
               dut.cpu.paging_inst.state, dut.cpu.paging_inst.req_is_write,
               dut.cpu.paging_inst.req_linear, dut.cpu.paging_inst.write_will_post,
               dut.cpu.paging_inst.mem_write_dly_grace, dut.cpu.paging_inst.mem_write_wait,
               dut.cpu.paging_inst.req_can_translate, dut.cpu.paging_inst.tlb_hit,
               dut.cpu.paging_inst.tlb_dirty, dut.cpu.paging_inst.req_tlb_dirty_ok,
               dut.cpu.paging_inst.live_valid, dut.cpu.paging_inst.live_store_posts,
               dut.cpu.paging_inst.fast_path_pending, dut.cpu.paging_inst.req_crossing,
               dut.cpu.paging_inst.req_offset);
      $display("TIMEOUT PGREQ dca=%0d dccand=%0d canacc=%0d dcready=%0d mreqcur=%0d macc=%0d mserv=%0d walkreq=%0d walkdone=%0d expost=%0d",
               dut.cpu.paging_inst.dcache_req_accepted, dut.cpu.paging_inst.req_mem_dcache_candidate,
               dut.cpu.paging_inst.req_can_translate,
               dut.cpu.memory_inst.cache_unit_inst.dcache_inst.cpu_ready,
               dut.cpu.mem_req_current, dut.cpu.mem_accepted, dut.cpu.mem_servicing,
               dut.cpu.paging_inst.walk_request, dut.cpu.paging_inst.walk_done,
               dut.cpu.paging_inst.req_mem_posted_done);
      $display("TIMEOUT DCACHE state=%0d stqcnt=%0d stqdrain=%0d drainblock=%0d mvld=%0d mw=%0d mem_busy=%0d ready_r=%0d",
               dut.cpu.memory_inst.cache_unit_inst.dcache_inst.state, dut.cpu.memory_inst.cache_unit_inst.dcache_inst.storeq_count,
               dut.cpu.memory_inst.cache_unit_inst.dcache_inst.storeq_draining,
               dut.cpu.memory_inst.cache_unit_inst.dcache_inst.drain_block_state,
               dut.cpu.memory_inst.cache_unit_inst.dcache_inst.mem_valid_r,
               dut.cpu.memory_inst.cache_unit_inst.dcache_inst.mem_write_r,
               dut.cpu.memory_inst.cache_unit_inst.dcache_inst.mem_busy,
               dut.cpu.memory_inst.cache_unit_inst.dcache_inst.ready_r);
      $display("TIMEOUT EXT extv=%0d extsrc=%0d extwr=%0d extdca=%0d mem_ready=%0d",
               dut.cpu.memory_inst.ext_valid_r, dut.cpu.memory_inst.bus_unit_inst.ext_src_r,
               dut.cpu.memory_inst.bus_unit_inst.ext_write_r, dut.cpu.memory_inst.bus_unit_inst.ext_dcache_accept,
               dut.cpu.memory_inst.ready);
      // The z486 memory fabric's own handshake. The stall holds
      // fast_path_pending with the demand request ACCEPTED and the bus idle, so
      // these are the terms that decide whether the read ever reported complete.
      $display("TIMEOUT CG code=%04x jis=%0d rd_hold=%0d fnt_act=%0d fnt_step=%0d base=%05x jis_base=%05x wk_act=%0d wk_state=%0d wk_req=%0d font_req=%0d font_left=%0d mem1_valid=%0d mem1_ready=%0d mem1_resp=%0d",
               dut.u_cg.cg_code, dut.u_cg.cg_jis, dut.u_cg.cg_rd_hold, dut.u_cg.fnt_act, dut.u_cg.fnt_step,
               dut.u_cg.fnt_base_r, dut.u_cg.cg_jis_base, dut.u_cg.wk_act, dut.u_cg.wk_state, dut.u_cg.wk_req,
               dut.font_req, dut.memory.font_left, dut.ext_mem1_valid, dut.ext_mem1_ready, dut.ext_mem1_resp_valid);
      $display("TIMEOUT FABRIC z_valid=%0d z_ready=%0d z_resp=%0d z_wr=%0d z_io=%0d z_addr=%08x | reqv=%0d acc=%0d comp=%0d vga=%0d isio=%0d isinta=%0d | extv=%0d extsrc=%0d dirpend=%0d dcpupend=%0d dcrdpend=%0d icrdpend=%0d | gv(tcr=%0d own=%0d ownplain=%0d st=%0d rdy=%0d rsp=%0d)",
               dut.cpu.memory_inst.valid, dut.cpu.memory_inst.ready,
               dut.cpu.memory_inst.resp_valid, dut.cpu.memory_inst.write,
               dut.cpu.memory_inst.io, {dut.cpu.memory_inst.addr, 2'b00},
               dut.cpu.memory_inst.dcache_req_valid, dut.cpu.memory_inst.dcache_req_accepted,
               dut.cpu.memory_inst.dcache_req_complete, dut.cpu.memory_inst.dcache_req_is_vga_mem,
               dut.cpu.memory_inst.dcache_req_is_io, dut.cpu.memory_inst.dcache_req_is_inta,
               dut.cpu.memory_inst.ext_valid_r, dut.cpu.memory_inst.bus_unit_inst.ext_src_r,
               dut.cpu.memory_inst.direct_rd_pending, dut.cpu.memory_inst.cache_unit_inst.dcache_cpu_rd_pending,
               dut.cpu.memory_inst.bus_unit_inst.dcache_rd_pending, dut.cpu.memory_inst.bus_unit_inst.icache_rd_pending,
               dut.memory.u_gvram_arb.grcg_tcr_gate, dut.memory.u_gvram_arb.cc_owns_grcg,
               dut.memory.u_gvram_arb.cc_owns_plain, dut.memory.u_grcg.gstate,
               dut.memory.u_grcg.cpu_ready, dut.memory.u_grcg.cpu_resp_valid);
      $display("PC TAIL: distinct addresses in the last 128 samples");
      n = 0;
      for (i = 0; i < 128; i = i + 1) begin
        if (pc_idx < 128) break;
        v = pc_hist[(pc_idx - 128 + i) % PC_HIST];
        dup = 0;
        for (j = 0; j < i; j = j + 1)
          if (pc_hist[(pc_idx - 128 + j) % PC_HIST] == v) dup = 1;
        if (!dup) begin
          $write("  %08x", v);
          n = n + 1;
          if (n % 6 == 0) $write("\n");
        end
      end
      $write("\n");
    end
  endtask

  // Inject keypresses while the CPU is in the boot menu (segment 1D00) so
  // the keyboard buffer is non-empty whenever the menu peeks (INT 18h AH=01).
  // Set-2 '1' (0x16); bit10 toggles per injection to mark the event edge.
  reg [15:0] key_tick = 0;
  reg key_state = 0;
  always @(posedge clk_sys) begin
    if (cpu_cs == 16'h1D00) begin
      key_tick <= key_tick + 16'd1;
      if (key_tick[8:0] == 9'd0) begin
        key_state <= ~key_state;
        ps2_key <= {key_state, 1'b1, 1'b0, 8'h16};
      end
    end
  end

  // Bounded ring of the most recent platform I/O accesses. A stall is almost
  // always a poll of a port the core does not implement, and the last few
  // accesses name it (and its data) directly.
  localparam IO_HIST = 24;
  reg [15:0] io_hist_addr [0:IO_HIST-1];
  reg [7:0]  io_hist_data [0:IO_HIST-1];
  reg        io_hist_wr   [0:IO_HIST-1];
  integer    io_hist_idx = 0;
  integer    io_hist_n   = 0;
  always @(posedge clk_sys) begin
    if (dut.device_io_wr || dut.device_io_rd) begin
      io_hist_addr[io_hist_idx] = dut.device_io_addr;
      io_hist_data[io_hist_idx] = dut.device_io_din;
      io_hist_wr[io_hist_idx]   = dut.device_io_wr;
      io_hist_idx = (io_hist_idx + 1) % IO_HIST;
      if (io_hist_n < IO_HIST) io_hist_n = io_hist_n + 1;
    end
  end

  // I/O ring buffer: the last 24 device accesses with their port and direction.
  // The unmapped-read counter saturating says the guest is looping, but not on
  // what; this names the ports. A stalled guest that polls a port expecting a
  // bit to change never exits if we answer a constant, so the loop's port is the
  // fix.
  reg [15:0] io_ring_port [0:23];
  reg        io_ring_wr   [0:23];
  reg [3:0]  io_ring_idx  = 0;
  integer    io_ring_n    = 0;
  always @(posedge clk_sys) begin
    if (dut.device_io_rd | dut.device_io_wr) begin
      io_ring_port[io_ring_idx] = dut.device_io_addr;
      io_ring_wr[io_ring_idx]   = dut.device_io_wr;
      io_ring_idx = (io_ring_idx + 1) % 24;
      if (io_ring_n < 24) io_ring_n = io_ring_n + 1;
    end
  end

  // ---- the pre-IPL fast-path stall at 0xFA641 -----------------------
  // The stall held the paging unit's fast_path_pending with the demand read already
  // ACCEPTED (ext_valid_r cleared, mem_servicing stuck) and the page unit back in
  // PG_IDLE, so the question was whether the fabric ever reports that read complete.
  // The stuck instruction is the `repe scasd` at ITF offset 0x263E whose architectural
  // EIP is the following `jnz`, 0xFA641. The per-cycle fabric trace is OFF by default
  // (80 lines) and asks for `TB_ARGS="+BOOTSTALL_TRACE"`; the one-line stall dump in
  // dump_pc_tail always reports the same state, and FASTRISK flags the contract
  // violation that caused it (an accept and a response in the SAME cycle) wherever it
  // occurs, so a regression prints it without the flag.
  reg        bsd_trace_en  = 1'b0;
  reg        fast_trace_on = 1'b0;
  reg [7:0]  fast_trace_n  = 8'd0;
  reg        fast_seen     = 1'b0;
  integer    fast_risk_n   = 0;
  initial begin
    if ($test$plusargs("BOOTSTALL_TRACE")) bsd_trace_en = 1'b1;
  end
  always @(posedge clk_sys) begin
    if (bsd_trace_en && !fast_seen && pc_now == 32'h000F_A641) begin
      fast_seen     <= 1'b1;
      fast_trace_on <= 1'b1;
      $display("FASTSTART cyc=%0d", tb_cycle);
    end
    if (fast_trace_on) begin
      $display("FAST c=%0d pc=%08x | z(v=%b rdy=%b resp=%b wr=%b io=%b addr=%08x) | req(v=%b acc=%b comp=%b vga=%b wr=%b isio=%b isinta=%b) | ext(v=%b src=%0d write=%b dirpend=%b dpupend=%b) | pg(st=%0d fastpend=%b serv=%b uc=%b busreq=%b) | dc(st=%0d ready=%b resp=%b mvld=%b) | gv(tcr=%b own=%b ownplain=%b st=%0d rdy=%b rsp=%b)",
        tb_cycle, pc_now,
        dut.cpu.memory_inst.valid, dut.cpu.memory_inst.ready, dut.cpu.memory_inst.resp_valid,
        dut.cpu.memory_inst.write, dut.cpu.memory_inst.io,
        {dut.cpu.memory_inst.addr, 2'b00},
        dut.cpu.memory_inst.dcache_req_valid, dut.cpu.memory_inst.dcache_req_accepted,
        dut.cpu.memory_inst.dcache_req_complete, dut.cpu.memory_inst.dcache_req_is_vga_mem,
        dut.cpu.memory_inst.dcache_req_write, dut.cpu.memory_inst.dcache_req_is_io,
        dut.cpu.memory_inst.dcache_req_is_inta,
        dut.cpu.memory_inst.ext_valid_r, dut.cpu.memory_inst.bus_unit_inst.ext_src_r,
        dut.cpu.memory_inst.bus_unit_inst.ext_write_r, dut.cpu.memory_inst.direct_rd_pending,
        dut.cpu.memory_inst.cache_unit_inst.dcache_cpu_rd_pending,
        dut.cpu.paging_inst.state, dut.cpu.paging_inst.fast_path_pending,
        dut.cpu.mem_servicing, dut.cpu.uc_active, dut.cpu.uc_busreq,
        dut.cpu.memory_inst.cache_unit_inst.dcache_inst.state, dut.cpu.memory_inst.cache_unit_inst.dcache_inst.ready_r,
        dut.cpu.memory_inst.cache_unit_inst.dcache_inst.cpu_resp_valid,
        dut.cpu.memory_inst.cache_unit_inst.dcache_inst.mem_valid_r,
        dut.memory.u_gvram_arb.grcg_tcr_gate, dut.memory.u_gvram_arb.cc_owns_grcg,
        dut.memory.u_gvram_arb.cc_owns_plain, dut.memory.u_grcg.gstate,
        dut.memory.u_grcg.cpu_ready, dut.memory.u_grcg.cpu_resp_valid);
      fast_trace_n <= fast_trace_n + 8'd1;
      if (fast_trace_n == 8'd80) fast_trace_on <= 1'b0;
    end
    // A demand READ on the VGA/DIRECT route accepted AND completed in the SAME cycle is the
    // contract violation that wedged this boot: the memory subsystem's responder contract
    // requires the accept and the response on separate cycles, and the paging unit latches
    // fast_path_pending on the accept edge, so a same-cycle completion is seen with the latch
    // still low and then never again. Writes complete ON the accept by design and the
    // map's combinational local RAM/ROM path answers in the accept cycle by design, so both are
    // excluded; the plane/device routes (GVRAM, GRCG, EGC, CG window, TRAM) are not.
    if (dut.cpu.memory_inst.dcache_req_accepted &&
        dut.cpu.memory_inst.dcache_req_complete &&
        !dut.cpu.memory_inst.dcache_req_write &&
        dut.cpu.memory_inst.dcache_req_is_vga_mem && fast_risk_n < 24) begin
      fast_risk_n = fast_risk_n + 1;
      $display("FASTRISK cyc=%0d pc=%08x extv=%b ready=%b resp=%b fastpend=%b",
        tb_cycle, pc_now, dut.cpu.memory_inst.ext_valid_r, dut.cpu.memory_inst.ready,
        dut.cpu.memory_inst.resp_valid, dut.cpu.paging_inst.fast_path_pending);
    end
  end

  // The free IDE ROM checks for the "IPL1" marker at es:4/es:6 before it calls
  // the IPL, so the guest executing at 1FC0:0000 proves the two-sector ATA read
  // delivered correct data. That is exactly what a device read-timing regression
  // breaks, and it is the assertion this bench was missing when the 17 unit
  // checks all passed with the disk completely broken.
  reg saw_ipl;
  always @(posedge clk_sys) if (cpu_cs == 16'h1FC0) saw_ipl <= 1'b1;

  // ---- the option-ROM window at the moment the BIOS calls it -------------
  // The main BIOS installs the IDE option ROM by far-calling D800:000C (the
  // pointer built at BANK6@0x5659-0x565F; the call itself is BANK6@0x5698 =
  // physical 0xF5698) and by the earlier option-ROM scan (BANK7@0x7EA3 ->
  // 0x7F24 -> 0xF560:0x1E, which far-calls each ROM's +0x15 entry). Both run
  // from segment D800, so the first fetch inside 0xD8000-0xD9FFF is the moment
  // 0x053D bit 4 decides whether the BIOS's call lands on the option ROM or on
  // guest RAM. The map's own byte-level behaviour is asserted in
  // tb_pc9821_memory_map.sv and tb_pc9821_iobus.sv (the ITF's 0x10/0x00/0x02/
  // 0x16 sequence); what this records is the integrated state at that moment.
  reg        rom_call_seen = 1'b0;
  reg        rom_call_open = 1'b0;
  reg [31:0] rom_call_pc = 32'd0;
  reg [63:0] rom_call_cycle = 64'd0;
  always @(posedge clk_sys) begin
    if (!rom_call_seen && pc_now >= 32'h000D_8000 && pc_now <= 32'h000D_9FFF) begin
      rom_call_seen  <= 1'b1;
      rom_call_open  <= dut.iobus.rom_gate_ide;
      rom_call_pc    <= pc_now;
      rom_call_cycle <= tb_cycle;
      $display("ROM CALL at pc=%08x cyc=%0d window=%0s d8=%02x top_bank=%0d",
               pc_now, tb_cycle, dut.iobus.rom_gate_ide ? "open" : "CLOSED",
               dut.iobus.pci_d8_select, dut.iobus.top_bank);
    end
  end

  // ATA command history: the last 16 bytes written to the command register
  // (0x64E), so the simulation's command sequence can be compared directly with
  // the hardware watchdog's K / X / Z telemetry.
  // The task-file registers the geometry commands depend on are captured
  // alongside each command: an IDP aborts because of exactly these two values,
  // so a history that records only the opcode cannot say which geometry the
  // guest asked for. The pre-edge samples are the values the command sees,
  // because the device's non-blocking updates land after this block runs.
  reg [7:0] ata_cmd_hist [0:15];
  reg [7:0] ata_cmd_scnt [0:15];
  reg [7:0] ata_cmd_head [0:15];
  integer   ata_cmd_idx = 0;
  integer   ata_cmd_n   = 0;
  // The first 64 commands are logged with their bank and drive/head: which IDE units the
  // machine's IDE ROM and DOS address is the question a second disk depends on.
  integer   ata_dev1_log = 0;
  always @(posedge clk_sys) begin
    if (dut.device_io_wr && dut.device_io_addr == 16'h064E && ata_dev1_log < 64) begin
      $display("ATA CMD %02x bank=%02x head=%02x cnt=%02x cyl=%02x%02x sec=%02x cyc=%0d",
               dut.device_io_din, dut.ata.channel_reg, dut.ata.drive_head, dut.ata.sector_count,
               dut.ata.cylinder_high, dut.ata.cylinder_low, dut.ata.sector_number, tb_cycle);
      ata_dev1_log = ata_dev1_log + 1;
    end
    if (dut.device_io_wr && dut.device_io_addr == 16'h064E) begin
      ata_cmd_hist[ata_cmd_idx] = dut.device_io_din;
      ata_cmd_scnt[ata_cmd_idx] = dut.ata.sector_count;
      ata_cmd_head[ata_cmd_idx] = dut.ata.drive_head;
      ata_cmd_idx = (ata_cmd_idx + 1) % 16;
      if (ata_cmd_n < 16) ata_cmd_n = ata_cmd_n + 1;
    end
  end

  // --- screen capture: what the framework would actually see, plus the text
  // --- the guest wrote to TRAM, so a wrong glyph can be told from wrong data.
  reg [23:0] fb [0:255999];
  integer fb_i;
  initial for (fb_i = 0; fb_i < 256000; fb_i = fb_i + 1) fb[fb_i] = 24'h000000;

  task automatic dump_tram_text;
    integer row, col;
    reg [7:0] ch;
    begin
      $display("TRAM TEXT (80x25, chars at even addresses):");
      for (row = 0; row < 25; row = row + 1) begin
        $write("  %0d| ", row);
        for (col = 0; col < 80; col = col + 1) begin
          ch = dut.u_crtc.u_text_mem.u_tram.ram[row * 160 + col * 2];
          if (ch >= 8'h20 && ch < 8'h7F) $write("%c", ch);
          else if (ch == 8'h00) $write(" ");
          else $write(".");
        end
        $write("\n");
      end
    end
  endtask

`ifdef USERDISK_CD
  // --- the CD's conversation (USERDISK_CD only): every ATA command at bank 1, every PACKET's
  // CDB as the drive executes it, every data phase and completion the drive enters (status,
  // ERROR, interrupt reason, byte count, sense key/ASC), and the bank-0 data-port reads that
  // return data while DEVICE 1 is selected there (an absent slave must not). +TRAM_EVERY=<n>
  // prints the text screen every n cycles, so a run to the DOS prompt can be read as it goes.
  reg [2:0] cdmon_st = 3'd0;
  int unsigned tram_every = 0;
  initial void'($value$plusargs("TRAM_EVERY=%d", tram_every));
  longint unsigned state_at = 0;   // +STATE_AT=<cycle>: the PIC and the drive's state, once
  initial void'($value$plusargs("STATE_AT=%d", state_at));
  always @(posedge clk_sys) begin
    cdmon_st <= dut.g_cdrom.atapi.st;
    if (dut.device_io_wr && dut.device_io_addr == 16'h064E && dut.g_cdrom.atapi.bank1)
      $display("CDMON CMD %02x drhd=%02x dev1=%0d nien=%0d cyc=%0d", dut.device_io_din,
               dut.g_cdrom.atapi.drhd, dut.g_cdrom.atapi.dev1, dut.g_cdrom.atapi.nien, tb_cycle);
    if (dut.g_cdrom.atapi.exec_go)
      $display("CDMON CDB %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x (cmd %02x) cyc=%0d",
               dut.g_cdrom.atapi.cdb[0], dut.g_cdrom.atapi.cdb[1], dut.g_cdrom.atapi.cdb[2],
               dut.g_cdrom.atapi.cdb[3], dut.g_cdrom.atapi.cdb[4], dut.g_cdrom.atapi.cdb[5],
               dut.g_cdrom.atapi.cdb[6], dut.g_cdrom.atapi.cdb[7], dut.g_cdrom.atapi.cdb[8],
               dut.g_cdrom.atapi.cdb[9], dut.g_cdrom.atapi.cdb[10], dut.g_cdrom.atapi.cdb[11],
               dut.g_cdrom.atapi.cmd, tb_cycle);
    if (dut.g_cdrom.atapi.st != cdmon_st && (dut.g_cdrom.atapi.st == 3'd0 || dut.g_cdrom.atapi.st == 3'd6))
      $display("CDMON %s st=%02x err=%02x ireason=%02x bytes=%0d skc=%0d(0 none,1 not-ready,2 illegal,3 aborted) ascc=%0d(0 none,1 invalid-field,2 n2r,3 no-medium,4 lba) irq=%0d cyc=%0d",
               (dut.g_cdrom.atapi.st == 3'd6) ? "DATA" : "DONE", dut.g_cdrom.atapi.status,
               dut.g_cdrom.atapi.error, dut.g_cdrom.atapi.sc, dut.g_cdrom.atapi.cy,
               dut.g_cdrom.atapi.skc, dut.g_cdrom.atapi.ascc, dut.g_cdrom.atapi.irq, tb_cycle);
    if (dut.device_io_rd && dut.ata_cs && !dut.g_cdrom.atapi.bank1 && dut.ata.drive_head[4] &&
        (dut.device_io_addr == 16'h0640 || dut.device_io_addr == 16'h0641) && dut.device_io_dout != 8'h00)
      $display("CDMON GHOST bank 0 DEV 1 data read %04x = %02x (master status %02x) cyc=%0d",
               dut.device_io_addr, dut.device_io_dout, dut.ata.status_reg, tb_cycle);
    if (state_at != 0 && tb_cycle == state_at)
      $display("STATE at cyc=%0d: PIC master imr=%02x irr=%02x isr=%02x, CD irq=%0d st=%0d daflag=%0d",
               tb_cycle, dut.irq_dbg_imr, dut.irq_dbg_irr, dut.irq_dbg_isr,
               dut.g_cdrom.atapi.irq, dut.g_cdrom.atapi.st, dut.g_cdrom.atapi.daflag);
    if (state_at != 0 && tb_cycle == state_at) begin
      $display("STATE halted=%0d", dut.cpu.halted);
      trap_dump(dut.cpu.desc_cache[1].base + dut.cpu.EIP);
    end
    if (tram_every != 0 && tb_cycle != 0 && (tb_cycle % tram_every) == 0) begin
      $display("CDMON TRAM at cyc=%0d", tb_cycle);
      dump_tram_text;
    end
  end
`endif

  // +CD_MOUNT_AT=<cycle> (and +CD_REMOUNT_AT=<cycle>): present the CD the way the MiSTer's MGL
  // does (delay="1"), as a slot-4 img_mounted pulse with img_size while the guest runs, instead
  // of at time 0 with the hard disk. The second is a re-insert, as an OSD mount would be.
  longint unsigned cd_mount_at = 0, cd_remount_at = 0;
  reg cd_late = 1'b0;
  initial begin
    if ($value$plusargs("CD_MOUNT_AT=%d", cd_mount_at)) cd_late = 1'b1;
    void'($value$plusargs("CD_REMOUNT_AT=%d", cd_remount_at));
  end
  always @(posedge clk_sys) begin
    if (cd_late && img1_fd != 0 && (tb_cycle == cd_mount_at || (cd_remount_at != 0 && tb_cycle == cd_remount_at))) begin
      void'($fseek(img1_fd, 0, 2));
      img_size <= 64'($ftell(img1_fd));
      hdd1_size <= 64'($ftell(img1_fd));
      hdd1_mounted <= 1'b1;
      $display("CD_FILE mounted late at cyc=%0d (%0d bytes)", tb_cycle, $ftell(img1_fd));
    end else if (cd_late) hdd1_mounted <= 1'b0;
  end

`ifdef USERDISK_CD
  // +CDLOG_FILE=<path>: the CD command log (CDROM_LOG_EN) exactly as pc9821_system hands it to the
  // top level's UART FIFO - every byte taken while dbg_uart_we is high (accept is tied high here) -
  // written raw, for tools/decode_cdlog.py.
  integer cdlog_fd = 0;
  initial begin : cdlog_open
    reg [1023:0] path;
    if ($value$plusargs("CDLOG_FILE=%s", path)) cdlog_fd = $fopen(path, "wb");
  end
  always @(posedge clk_sys) if (cdlog_fd != 0 && dut.dbg_uart_we) begin
    $fwrite(cdlog_fd, "%c", dut.dbg_uart_byte);
    $fflush(cdlog_fd);
  end
`endif

  task automatic dump_screen(input [1023:0] path);
    integer fh, i;
    begin
      fh = $fopen(path, "wb");
      if (fh == 0) $display("FB: cannot open %0s", path);
      else begin
        $fwrite(fh, "P6\n640 400\n255\n");
        for (i = 0; i < 256000; i = i + 1)
          $fwrite(fh, "%c%c%c", fb[i][23:16], fb[i][15:8], fb[i][7:0]);
        $fclose(fh);
        $display("FB: wrote %0s", path);
      end
    end
  endtask

  integer cap_de;
  // +FB_LAST: the dumped screen is the LAST complete frame instead of the first 256000
  // active pixels ever emitted (which is the boot's first frame, usually blank). The index
  // restarts at each VSYNC rising edge; cap_de keeps counting every active pixel as before.
  reg     fb_last = 1'b0;
  initial fb_last = $test$plusargs("FB_LAST");
  integer cap_frame = 0;
  reg     vsync_d = 1'b0;
  // +FB_EVERY=<n> (with +FB_LAST): the last complete frame, every n cycles, as fb_<cycle>.ppm
  // in the run directory - a long guest run's screen history.
  longint unsigned fb_every = 0;
  initial void'($value$plusargs("FB_EVERY=%d", fb_every));
  always @(posedge clk_sys)
    if (fb_every != 0 && tb_cycle != 0 && (tb_cycle % fb_every) == 0) begin : fb_every_dump
      reg [1023:0] p;
      p = {1024{1'b0}};
      $sformat(p, "fb_%0d.ppm", tb_cycle);
      dump_screen(p);
    end
  always @(posedge clk_sys) begin
    vsync_d <= video_vsync;
    if (video_vsync && !vsync_d) cap_frame <= 0;
    else if (video_ce && video_blank_n) cap_frame <= cap_frame + 1;
    if (video_ce && video_blank_n) begin
      if (fb_last) begin
        if (cap_frame < 256000) fb[cap_frame] <= {video_r[7:0], video_g[7:0], video_b[7:0]};
      end else if (cap_de < 256000) fb[cap_de] <= {video_r[7:0], video_g[7:0], video_b[7:0]};
      cap_de <= cap_de + 1;
    end
  end

  // Pixels the framework would actually see. Reported rather than asserted: nothing has
  // ever checked that this core emits a non-zero pixel, and four scanout defects once
  // left TRAM correct with a black screen. video_off -- the stub that blanked every
  // HDMI pixel -- IS asserted, because that one is unambiguous.
  integer nonblack = 0;
  always @(posedge clk_sys)
    if (video_ce && video_blank_n && (video_r || video_g || video_b))
      nonblack <= nonblack + 1;

  // Which CG store addresses the responder has committed to. Monotone, so it survives
  // log truncation and does not depend on our own index formula: it answers "did a
  // write ever land at store word 0x818/0x819?", which is the current boot blocker.
  reg [31:0] cg_wr_mask = 32'd0;
  reg [7:0]  cg_wr_count [0:31];
  integer    cg_i;
  initial for (cg_i = 0; cg_i < 32; cg_i = cg_i + 1) cg_wr_count[cg_i] = 8'd0;
  always @(posedge clk_sys)
    if (dut.u_cg.cg_wr_win &&
        dut.u_cg.cg_wr_addr >= 13'h800 &&
        dut.u_cg.cg_wr_addr < 13'h820) begin
      cg_wr_mask[dut.u_cg.cg_wr_addr[4:0]] <= 1'b1;
      if (cg_wr_count[dut.u_cg.cg_wr_addr[4:0]] != 8'hFF)
        cg_wr_count[dut.u_cg.cg_wr_addr[4:0]] <=
          cg_wr_count[dut.u_cg.cg_wr_addr[4:0]] + 8'd1;
    end

  // ---- SDIP access history -------------------------------------------------
  // The authentic ITF's configuration check is a 24-byte write-then-read-back
  // across two banks, and when it fails nothing else in this bench can say why:
  // the generic IO ring above logs *device* ports only, and the software-DIP
  // switch lives in the iobus decode. Log one entry per transaction.
  localparam integer SDIP_HIST = 96;
  reg [15:0] sdip_hist_addr [0:SDIP_HIST-1];
  reg [7:0]  sdip_hist_data [0:SDIP_HIST-1];
  reg        sdip_hist_wr   [0:SDIP_HIST-1];
  integer    sdip_hist_idx = 0;
  integer    sdip_hist_n   = 0;
  // Transaction capture, not level edges or content dedup: identical consecutive
  // reads still count. The I/O fabric's S_BYTE/S_DEVWAIT capture owns the byte.
  // The switch ports, plus the firmware/ROM-window control registers: those
  // four decide whether the option ROM is visible at all, and a firmware that
  // copies from 0xD8000 while the window is shut gets silence.
  wire sdip_access = !reset && (io_read_capture ||
                     ((dut.iobus.state == dut.iobus.S_BYTE) && dut.iobus.request_write)) &&
                     ((dut.iobus.port_addr[7:0] == 8'h1E) ||
                      (dut.iobus.port_addr == 16'h8F1F) ||
                      (dut.iobus.port_addr == 16'h053D) ||
                      (dut.iobus.port_addr == 16'h063C) ||
                      (dut.iobus.port_addr == 16'h043D) ||
                      (dut.iobus.port_addr == 16'h043F));
  always @(posedge clk_sys) begin
    if (sdip_access) begin
      sdip_hist_addr[sdip_hist_idx] = dut.iobus.port_addr;
      sdip_hist_data[sdip_hist_idx] = dut.iobus.request_write ? dut.iobus.lane_wdata
                                                             : dut.iobus.lane_rdata;
      sdip_hist_wr[sdip_hist_idx]   = dut.iobus.request_write;
      sdip_hist_idx = (sdip_hist_idx + 1) % SDIP_HIST;
      if (sdip_hist_n < SDIP_HIST) sdip_hist_n = sdip_hist_n + 1;
    end
  end

  // ---- the ITF's PIT self-test window -------------------------------------
  // BANK4@0x038F is the ITF's timer-aliveness test: for each entry of its
  // table (control port, data port) it writes the control byte, writes 0xFF to
  // the data port, writes a second control byte (a counter-latch command) and
  // reads the data port, requiring the read to differ from what it wrote. The
  // read is the latched count of a counter loaded with 0xFF, so the test only
  // passes if at least one PIT tick falls between the data write and the latch
  // write -- a race between the PIT input clock (2.4576 MHz against the 50 MHz
  // system clock, so 20.34 cycles per tick) and the CPU's I/O access time.
  // Printed with the cycle of every access so the margin is a number, not an
  // argument: the failing entry is the one whose gap is under one tick.
  integer pit_evt_n = 0;
  always @(posedge clk_sys) begin
    if ((dut.device_io_addr == 16'h3FDB || dut.device_io_addr == 16'h3FDF) &&
        pit_evt_n < 48) begin
      if (dut.device_io_wr) begin
        $display("PITTEST w cyc=%0d port=%04x data=%02x c1=%04x latch1=%0d/%04x mode1=%0d rw1=%0d run1=%0d",
                 tb_cycle, dut.device_io_addr, dut.device_io_din,
                 dut.interrupts.pit.count[1], dut.interrupts.pit.read_latched[1],
                 dut.interrupts.pit.read_latch[1], dut.interrupts.pit.mode[1],
                 dut.interrupts.pit.rw_mode[1], dut.interrupts.pit.running[1]);
        pit_evt_n = pit_evt_n + 1;
      end else if (dut.device_io_rd) begin
        $display("PITTEST r cyc=%0d port=%04x dout=%02x latch1=%0d/%04x c1=%04x",
                 tb_cycle, dut.device_io_addr, dut.device_io_dout,
                 dut.interrupts.pit.read_latched[1], dut.interrupts.pit.read_latch[1],
                 dut.interrupts.pit.count[1]);
        pit_evt_n = pit_evt_n + 1;
      end
    end
  end

  // ---- bounded ITF chipset/config transaction transcript (+ITF_TRACE) -----
  // Read bytes are sampled at the I/O fabric's capture edge (S_BYTE/S_DEVWAIT),
  // not at the request strobe. Repeated identical transactions are not deduped.
  reg itf_trace = 1'b0;
  integer itf_evt_n = 0;
  reg [15:0] itf_59a_last = 16'hFFFF;
  initial itf_trace = $test$plusargs("ITF_TRACE");
  always @(posedge clk_sys) begin
    if (itf_trace && !reset && itf_evt_n < 600) begin
      if (((dut.iobus.state == dut.iobus.S_BYTE) && dut.iobus.request_write) ||
          io_read_capture) begin
        if ((dut.iobus.port_addr >= 16'h18F0 && dut.iobus.port_addr <= 16'h18F3) ||
            dut.iobus.port_addr == 16'h0439 || dut.iobus.port_addr == 16'h043F ||
            dut.iobus.port_addr == 16'h043D || dut.iobus.port_addr == 16'h053D ||
            dut.iobus.port_addr == 16'h00F0 ||
            (io_a9_read && (dut.u_cg.cg_ram_addr == 13'h815 ||
             dut.u_cg.cg_ram_addr == 13'h0497 ||
             dut.u_cg.cg_ram_addr == 13'h1CA7 ||
             dut.u_cg.cg_ram_addr == 13'h1C67 ||
             dut.u_cg.cg_ram_addr >= 13'h1C6D && dut.u_cg.cg_ram_addr <= 13'h1C6F))) begin
          $display("ITFIO %s port=%04x bus=%02x st=%04x pc=%08x cyc=%0d",
                   dut.iobus.request_write ? "W" : "R", dut.iobus.port_addr,
                   dut.iobus.request_write ? dut.iobus.lane_wdata : dut.iobus.lane_rdata,
                   dut.u_cg.cg_ram_addr, pc_now, tb_cycle);
          itf_evt_n = itf_evt_n + 1;
        end
      end
      if ({ram_byte(32'h59B), ram_byte(32'h59A)} !== itf_59a_last) begin
        itf_59a_last <= {ram_byte(32'h59B), ram_byte(32'h59A)};
        $display("ITFWA stored 059A=%04x pc_proxy=%08x cyc=%0d",
                 {ram_byte(32'h59B), ram_byte(32'h59A)}, pc_now, tb_cycle);
      end
    end
  end

  // ---- the memory-size chain, traced --------------------------------------
  // The ITF checks an image-PRESENT flag at CG code 0x7257 row 0x27 and reads
  // its extended-memory size out of code 0x7157 row 0x27. Both are named in
  // the ITF's disassembly and the machine's /MEMSW capture reads 00 at both on the
  // machine. The store address packs the window's {code[14:8], code[0], lr,
  // row}, so code 0x7157 row 0x27 IS 0x1C67 and 0x7257 row 0x27 IS 0x1CA7 -
  // the very addresses the disassembly names, which is how the packing is confirmed.
  //
  // This prints who writes each cell and with what, and what each read saw, so
  // the chain from the 0x530/0x531 register file to the printed size is
  // MEASURED rather than inferred - which is the whole point, because the
  // previous conclusion about these cells was reached by inference and the
  // machine then contradicted it. Gated on +MEMSW_TRACE so an acceptance run's
  // output is unchanged.
  localparam [12:0] CELL_SIZE = {7'h71, 1'b1, 1'b0, 4'h7};   // code 0x7157 row 0x27
  localparam [12:0] CELL_PRES = {7'h72, 1'b1, 1'b0, 4'h7};   // code 0x7257 row 0x27
  reg [7:0] msw_addr_d = 8'hFF;
  reg       memsw_trace = 1'b0;
  integer   msw_evt_n = 0;
  initial memsw_trace = $test$plusargs("MEMSW_TRACE");
  always @(posedge clk_sys) begin
    if (memsw_trace && msw_evt_n < 400) begin
      // Every write to the 0x530 address latch: this is the ITF programming
      // the register file, and the sequence of addresses is what tells a
      // register file the firmware populates from a strap it reads.
      if (dut.iobus.msw_addr !== msw_addr_d) begin
        msw_addr_d <= dut.iobus.msw_addr;
        $display("MSW  0530<- %02x cyc=%0d pc=%08x", dut.iobus.msw_addr, tb_cycle, pc_now);
      end
      if (dut.u_cg.cg_wr_win &&
          (dut.u_cg.cg_wr_addr == CELL_SIZE || dut.u_cg.cg_wr_addr == CELL_PRES)) begin
        $display("CGWR %s addr=%04x data=%02x code=%04x lr=%0d cyc=%0d pc=%08x",
                 (dut.u_cg.cg_wr_addr == CELL_SIZE) ? "SIZE" : "PRES",
                 dut.u_cg.cg_wr_addr, dut.u_cg.cg_wr_data,
                 dut.u_cg.cg_code, dut.u_cg.cg_lr, tb_cycle, pc_now);
        msw_evt_n = msw_evt_n + 1;
      end
      if (cfg_bus_read && (cfg_bus_store == CELL_SIZE || cfg_bus_store == CELL_PRES)) begin
        $display("CGRD %s addr=%04x bus=%02x code=%04x lr=%0d cyc=%0d pc=%08x",
                 (cfg_bus_store == CELL_SIZE) ? "SIZE" : "PRES",
                 cfg_bus_store, cfg_bus_byte,
                 dut.u_cg.cg_code, dut.u_cg.cg_lr, tb_cycle, pc_now);
        msw_evt_n = msw_evt_n + 1;
      end
    end
  end

  // ---- the route-isolation collision, captured ---------------------------
  // The design's own route-isolation assertion (pc9821_memory_subsystem) aborts the run
  // BEFORE the ITF's memory-switch block is ever reached (this run shows zero
  // 0x530 writes), so that abort is what currently masks the memory-size defect.
  // But WHICH routes answer together, and at what address, is what separates a
  // memory-correctness defect from a size defect - two routes driving one read
  // is corrupt data, and a corrupt region would follow the mapping exactly as
  // the printed address does. Latched one cycle before the DUT's $fatal ends
  // the simulation, because nothing can be printed after it.
  // The TRAM bridge and the CG byte window are ONE responder now (pc9821_window_responder,
  // `win_*`), so the two old columns collapse into one -- which is exactly what the merge
  // claims: they can no longer answer two requests at once, because they are one engine and
  // the route select feeds it one request at a time.
  // A line read's beats are the routes' OWN responses now (P3): the two walking routes strobe
  // their word beats, the constant routes (open bus, PEGC regs) answer on cpu_resp_valid, and
  // the map route has no line form at all.
  wire [3:0] route_resp_n =
      {3'b000, dut.memory.map_cpu_resp_valid} +
      {3'b000, dut.memory.gvram_cpu_resp_valid} +
      {3'b000, dut.memory.win_cpu_resp_valid} +
      {3'b000, dut.memory.open_cpu_resp_valid} +
      {3'b000, dut.memory.gvram_cpu_line_word_valid} +
      {3'b000, dut.memory.win_cpu_line_word_valid};
  reg collision_seen = 1'b0;
  always @(posedge clk_sys) begin
    if (memsw_trace && !collision_seen && route_resp_n >= 2) begin
      collision_seen <= 1'b1;
      $display("ROUTE COLLISION cyc=%0d pc=%08x cs:eip=%04x:%08x zaddr=%08x zwr=%0d n=%0d",
               tb_cycle, pc_now, cpu_cs, cpu_eip, dut.z_addr, dut.z_write, route_resp_n);
      $display("  word: map=%0d gvram=%0d win=%0d open=%0d",
               dut.memory.map_cpu_resp_valid, dut.memory.gvram_cpu_resp_valid,
               dut.memory.win_cpu_resp_valid,
               dut.memory.open_cpu_resp_valid);
      $display("  line beats: gvram=%0d win=%0d",
               dut.memory.gvram_cpu_line_word_valid, dut.memory.win_cpu_line_word_valid);
    end
  end

  // ---- watchpoint on the ITF's SDIP failure target ------------------------
  // Every branch of the authentic ITF's switch verification jumps to
  // 0xFC7B2 when a check fails, and the repair routine it lands in looks the
  // same for all of them. The PC ring already holds the check that jumped, and
  // the SDIP array holds what we stored, so one dump at the first hit names the
  // failing byte instead of leaving it to inference.
  // Watch the option-ROM window's enable line: the ITF's copy from D8000:0000
  // only works while it is asserted, and if it is never asserted the shadow is
  // zeros and the ITF's signature check fails with no other clue.
  reg rom_gate_d = 0;
  reg [7:0] d8sel_d = 0;
  always @(posedge clk_sys) begin
    rom_gate_d <= dut.iobus.rom_gate_ide;
    d8sel_d    <= dut.iobus.pci_d8_select;
    if (dut.iobus.rom_gate_ide != rom_gate_d)
      $display("ROM GATE (0x53D bit 4) -> %0d at cs:eip=%04x:%08x",
               dut.iobus.rom_gate_ide, cpu_cs, cpu_eip);
    if (dut.iobus.pci_d8_select != d8sel_d)
      $display("D8 SELECT (0x63C) -> %02x at cs:eip=%04x:%08x",
               dut.iobus.pci_d8_select, cpu_cs, cpu_eip);
  end

  // Did the ITF ever copy anything into its shadow at 0x98000? Its own routine
  // at 0xF8215 does `es=0x9800, ds=0xd800, rep movsw 8 KiB`, so the first
  // non-zero word there is that copy (or a later one).
  reg shadow_seen = 0;
  always @(posedge clk_sys) begin
    if (!shadow_seen && ram[32'h0009_8000 >> 2] != 32'h0000_0000) begin
      shadow_seen <= 1;
      $display("SHADOW COPY started at cs:eip=%04x:%08x gate=%0d (first word %08x)",
               cpu_cs, cpu_eip, dut.iobus.rom_gate_ide, ram[32'h0009_8000 >> 2]);
    end
  end
  // And where the ITF's copy instruction is, so a miss is unambiguous.
  reg copy_pc_seen = 0;
  always @(posedge clk_sys) begin
    if (!copy_pc_seen && pc_now == 32'h000FC215) begin
      copy_pc_seen <= 1;
      $display("ITF REACHED THE COPY at 0xFC215 gate=%0d d8sel=%02x",
               dut.iobus.rom_gate_ide, dut.iobus.pci_d8_select);
    end
  end

  // ---- The IDE candidate-drive byte: the ITF's store and the ROM's read ----
  // The ITF computes the byte from system-PPI port 0xF0 (BANK4@0x19DF-0x19F2:
  // port-0xF0 bit5 -> byte bit0, bit6 -> byte bit2, then xor 5) and stores it
  // through ES=0x98E8 under window 0 = 0x0E, which aliases physical 0xF8E90.
  // The IDE option ROM reads the same physical address back at BANK3@0x078E and
  // probes one of eight slots per set bit; a zero byte probes none, so no ATA
  // command is ever issued. Watch the memory bus at both ends, because the
  // translation is the open question: the store's CPU address is 0x98E90 and
  // its TARGET is the selected bank's byte 0x0E90.
  reg drv_wr_seen = 0;
  reg drv_rd_seen = 0;
  reg drv_rd_pending = 0;
  reg [31:0] drv_rd_pc = 32'd0;
  reg [3:0]  drv_rd_top = 4'd0;
  reg [31:0] drv_rd_mem = 32'd0;
  reg stop_on_drivebyte = 0;
  integer drv_wr_n = 0;
  integer packbyte_n = 0;
  // E90WATCH: every CPU-side access to 0x98E90 with window 0 moved to 0x0E, both
  // directions, with the backend target the map produced. The DRIVEBYTE probes
  // above log the two ENDS; this logs the TRANSLATION, which is what decides
  // whether the ITF's store and the option ROM's read touch the same byte.
  integer e90_n = 0;
  // INTAWATCH: every interrupt the CPU actually ACKNOWLEDGES, with the vector and
  // the PIC registers. The FDD path polls work-area 0x55E, which only the FDD ISR
  // (BANK7 0x7AF7, `or [es:0x55e],ah` at 0x7B53) writes; if the vector never
  // appears here the IRQ is not being delivered and the poll can only time out.
  integer inta_n = 0;
  reg z_inta_d = 1'b0;
  // FDDISR: the BIOS FDD completion ISR's entry (physical 0xF8000 + 0x7AF7). A run in
  // which IRQ11 is delivered (INTAWATCH vector 0x13) but this body never executes says
  // the handler at IVT 0x13 is NOT the FDD ISR, which is why work-area 0x55E stays 0.
  reg fdd_isr_seen = 1'b0;
  always @(posedge clk_sys) begin
    if ((pc_now == 32'h000F_FAF7) && !fdd_isr_seen) begin
      fdd_isr_seen <= 1'b1;
      $display("FDDISR entered at cyc=%0d (the BIOS FDD ISR body, F800:7AF7)", tb_cycle);
    end
  end
  // +INTAWATCH_AFTER=<cycle> (+INTAWATCH_N=<n>, default 200): n more INTAWATCH lines from that
  // cycle on, past the first 40 - the vectors of a guest's interrupt traffic late in a run.
  longint unsigned intaw_after = 0;
  integer intaw_n = 200, intaw_cnt = 0;
  initial begin
    void'($value$plusargs("INTAWATCH_AFTER=%d", intaw_after));
    void'($value$plusargs("INTAWATCH_N=%d", intaw_n));
  end
  always @(posedge clk_sys) begin
    z_inta_d <= dut.z_inta;
    if (dut.z_inta && !z_inta_d && ((inta_n < 40) ||
        ((intaw_after != 0) && (tb_cycle >= intaw_after) && (intaw_cnt < intaw_n)))) begin
      if (inta_n >= 40) intaw_cnt = intaw_cnt + 1;
      inta_n = inta_n + 1;
      $display("INTAWATCH #%0d cyc=%0d pc=%08x vector=%02x fdc_irq=%b ata_irq=%b imr=%02x irr=%02x isr=%02x | slave ir=%02x imr=%02x irr=%02x isr=%02x",
               inta_n, tb_cycle, pc_now, dut.inta_din[7:0], dut.fdc_irq, dut.ata_irq,
               dut.irq_dbg_imr, dut.irq_dbg_irr, dut.irq_dbg_isr, dut.interrupts.slave_irq,
               dut.interrupts.slave_dbg_imr, dut.interrupts.slave_dbg_irr, dut.interrupts.slave_dbg_isr);
    end
  end
  always @(posedge clk_sys) begin
    if ((dut.memory.cpu_addr == 32'h0009_8E90) && (dut.iobus.win0_sel == 8'h0E) &&
        (e90_n < 24)) begin
      e90_n = e90_n + 1;
      $display("E90WATCH pc=%08x %s be=%b din=%08x win0=%02x gate=%0d top_bank=%0d -> mem=%08x mvalid=%0d mwrite=%0d",
               pc_now, dut.memory.cpu_write ? "wr" : "rd", dut.memory.cpu_be,
               dut.memory.cpu_din, dut.iobus.win0_sel, dut.iobus.bios_ram_gate,
               dut.iobus.top_bank, ext_mem0_addr, ext_mem0_valid, ext_mem0_write);
    end
  end
  always @(posedge clk_sys) begin
    // The ITF's candidate-drive store: ES=0x98E8, offset 0x10, with window 0
    // moved to 0x0E. The moved window is what makes it the drive byte and not
    // the ordinary RAM at 0x98E90 (which the same PC writes with window 0 = 0x08
    // during POST).
    if (dut.memory.cpu_valid && dut.memory.cpu_ready && dut.memory.cpu_write &&
        (dut.memory.cpu_addr == 32'h0009_8E90) &&
        (dut.iobus.win0_sel != 8'h08) && (drv_wr_n < 16)) begin
      drv_wr_seen <= 1;
      drv_wr_n = drv_wr_n + 1;
      $display("DRIVEBYTE WR cpu=%08x win0=%02x -> mem=%08x data=%02x be=%b pc=%08x gate=%0d top_bank=%0d",
               dut.memory.cpu_addr, dut.iobus.win0_sel, ext_mem0_addr,
               dut.memory.cpu_din[7:0], dut.memory.cpu_be, pc_now,
               dut.iobus.bios_ram_gate, dut.iobus.top_bank);
    end
    // SAMPLE AT THE RESPONSE, NOT THE ACCEPT. The map's cpu_dout is the backend's
    // REGISTERED output, so on the accept cycle it still holds the PREVIOUS access's
    // value -- sampling it there reported 0x00 ("the ROM probes no slot") on trees where
    // the ROM went on to issue IDENTIFY, and earlier runs read that zero as the guest's
    // decision. The accept is latched; the byte is taken when the response lands.
    if (!drv_rd_seen && !drv_rd_pending && dut.memory.cpu_valid && dut.memory.cpu_ready &&
        !dut.memory.cpu_write && (dut.memory.cpu_addr == 32'h000F_8E90) &&
        (pc_now >= 32'h000D_8000) && (pc_now <= 32'h000D_9FFF)) begin
      drv_rd_pending <= 1'b1;
      drv_rd_pc      <= pc_now;
      drv_rd_top     <= dut.iobus.top_bank;
      drv_rd_mem     <= ext_mem0_addr;
    end
    if (drv_rd_pending && dut.memory.cpu_resp_valid) begin
      drv_rd_pending <= 1'b0;
      drv_rd_seen <= 1;
      // The DATA is the point of this line: the option ROM probes one channel
      // per set bit of the byte it reads, so 0x04 means "probe channel 2" and
      // 0x00 means "probe nothing" -- the whole defect in one number.
      $display("DRIVEBYTE RD by option ROM cpu=%08x mem=%08x data=%02x pc=%08x top_bank=%0d",
               32'h000F_8E90, drv_rd_mem, dut.memory.cpu_dout[7:0],
               drv_rd_pc, drv_rd_top);
      // The two storage layers, so "which byte did the ROM actually read" is answered by
      // value: the PACK's BIOS-top slot (what the window shows with the shadow off) and
      // the SHADOW at 0x58000 past it (what it shows once 0x043F's 0x8 nibble is on and a
      // gated store has landed).
      $display("DRIVEBYTE pack[%08x]=%02x shadow[%08x]=%02x at the read (cyc=%0d)",
               sdram_pack_lo + 32'h0002_0000 + 32'h0E90,
               ram_byte(sdram_pack_lo + 32'h0002_0000 + 32'h0E90),
               sdram_pack_lo + 32'h0010_0000 + 32'h0005_8000 + 32'h0E90,
               ram_byte(sdram_pack_lo + 32'h0010_0000 + 32'h0005_8000 + 32'h0E90),
               tb_cycle);
      if (stop_on_drivebyte) stop_now <= 1'b1;
    end
    // The authoritative end: any store that reaches a pack byte at offset 0x0E90,
    // whichever CPU address produced it. With the top-window shadow rule the
    // ITF's window-0 store targets the BIOS-top slot (pack + 0x20000); the ITF
    // slot (pack + 0x00000) is printed too, so a run that still routes it there
    // says so rather than staying silent.
    if (ext_mem0_valid && ext_mem0_ready && ext_mem0_write &&
        (ext_mem0_addr[14:0] == 15'h0E90) && (ext_mem0_addr >= 32'h0200_0000) &&
        (tb_cycle > 1_000_000) && (packbyte_n < 8)) begin
      packbyte_n = packbyte_n + 1;
      $display("PACKBYTE WR mem=%08x data=%02x be=%b pc=%08x gate=%0d top_bank=%0d win0=%02x",
               ext_mem0_addr, ext_mem0_din[7:0], ext_mem0_be, pc_now,
               dut.iobus.bios_ram_gate, dut.iobus.top_bank, dut.iobus.win0_sel);
    end
  end

  reg drv_pc_seen = 0;
  always @(posedge clk_sys) begin
    if (!drv_pc_seen && (pc_now >= 32'h000F_99CE) && (pc_now <= 32'h000F_99F8)) begin
      drv_pc_seen <= 1;
      $display("DRIVEBYTE BLOCK entered at pc=%08x cyc=%0d win0=%02x gate=%0d top_bank=%0d",
               pc_now, tb_cycle, dut.iobus.win0_sel, dut.iobus.bios_ram_gate,
               dut.iobus.top_bank);
    end
  end

  // STRAPREAD: what a read of 0xF0 ACTUALLY returns here, because one diagnosis
  // held that the device-port priority shadows the 0xA9 strap arm, while the port
  // classifier puts 0xF0 among the system ports and NOT the device ports -- so the
  // arm should be reached. One trace settles
  // which, and the ITF's own bitmap arithmetic makes the value testable: 0xA9
  // gives bitmap 0x04, and anything with bits 5 and 6 both set gives 0x00.
  reg         strap_first_seen = 0;
  integer     strap_odd_n = 0;
  integer     strap_all_n = 0;
  always @(posedge clk_sys) begin
    if ((dut.iobus.port_addr == 16'h00F0) && (dut.iobus.lane == 2'd0)) begin
      if (!strap_first_seen) begin
        strap_first_seen <= 1;
        $display("STRAPREAD FIRST cyc=%0d port=%04x device_port=%0d lane_rdata=%02x state=%0d we=%0d pc=%08x",
                 tb_cycle, dut.iobus.port_addr, dut.iobus.device_port,
                 dut.iobus.lane_rdata, dut.iobus.state, dut.iobus.request_write, pc_now);
      end
      // EVERY read, capped only to keep the log readable: the earlier version logged
      // only the first and the odd ones, so a later read that DID return 0xA9 was
      // invisible and the question "does the ITF's own 0xF0 read happen?" could not
      // be answered from the log at all.
      if ((dut.iobus.state == pc9821_ports_pkg::S_IOWAIT) && !dut.iobus.request_write && (strap_all_n < 24)) begin
        strap_all_n = strap_all_n + 1;
        $display("STRAPREAD cyc=%0d hexa=%02x device_port=%0d cs_eip=%08x pc_now=%08x",
                 tb_cycle, dut.iobus.lane_rdata, dut.iobus.device_port, pc_now, pc_now);
      end
      if ((dut.iobus.lane_rdata != 8'hA9) && (strap_odd_n < 8)) begin
        strap_odd_n = strap_odd_n + 1;
        $display("STRAPREAD NOT-A9 cyc=%0d port=%04x device_port=%0d lane_rdata=%02x state=%0d we=%0d pc=%08x",
                 tb_cycle, dut.iobus.port_addr, dut.iobus.device_port,
                 dut.iobus.lane_rdata, dut.iobus.state, dut.iobus.request_write, pc_now);
      end
    end
  end

  // Every store that lands anywhere in the BIOS-top board slot's 0x0E90 row, and
  // every store the CPU makes to guest 0x98E90 regardless of byte enables, because
  // the drive byte ends at 0x00 and the ITF's own store is a BYTE while the writes
  // seen so far are words. Uncapped and with be, so which store is which is a
  // reading rather than a guess.
  integer drv_any_n = 0;
  always @(posedge clk_sys) begin
    if (dut.memory.cpu_valid && dut.memory.cpu_ready && dut.memory.cpu_write &&
        (dut.memory.cpu_addr == 32'h0009_8E90) && (drv_any_n < 24)) begin
      drv_any_n = drv_any_n + 1;
      $display("DRVSTORE cyc=%0d be=%b data=%02x win0=%02x phys=%08x gate=%0d pc=%08x",
               tb_cycle, dut.memory.cpu_be, dut.memory.cpu_din[7:0],
               dut.iobus.win0_sel, ext_mem0_addr, dut.iobus.bios_ram_gate, pc_now);
    end
    if (ext_mem0_valid && ext_mem0_ready && ext_mem0_write &&
        (ext_mem0_addr[14:0] == 15'h0E90) && (tb_cycle > 1_000_000) && (drv_any_n < 48)) begin
      drv_any_n = drv_any_n + 1;
      $display("PACKZERO cyc=%0d mem=%08x data=%02x be=%b pc=%08x win0=%02x",
               tb_cycle, ext_mem0_addr, ext_mem0_din[7:0], ext_mem0_be, pc_now,
               dut.iobus.win0_sel);
    end
  end

  // The segment is not exposed as a port and adding one would mean editing the
  // pinned CPU submodule, but the physical address of those reads gives it
  // directly: es = (addr - offset) >> 4. Watch the memory bus for accesses made
  // while the PC is in that check.
  reg es_probe = 0;
  always @(posedge clk_sys) begin
    if (ext_mem0_valid && ext_mem0_ready && !ext_mem0_write &&
        (pc_now >= 32'h000FC670) && (pc_now <= 32'h000FC690) && !es_probe) begin
      $display("ITF READS es:0x%02x at physical %08x -> es=0x%04x (pc=%08x)",
               ext_mem0_addr[7:0], ext_mem0_addr,
               (ext_mem0_addr - ext_mem0_addr[7:0]) >> 4, pc_now);
    end
  end

  // The software-DIP verification (BANK4@0xFC6xx): the marker check at
  // 0xFC677/0xFC67D reads es:0x11 into AH and es:0x13 into AL and wants 0xAA55
  // at 0xFC681; if that passes, 0xFC699..0xFC6B5 sums the ten bytes at
  // es:[3],[5],...,[0x15] into BL and wants zero mod 256, with the di==5 byte
  // mirrored to port 0x31.
  //
  // There is deliberately NO probe on a pc_now equality here. Those addresses
  // sit on the FETCH stream, which runs ahead of execution and walks past a
  // not-taken branch, so `pc_now == 0xFC686` (the comparison) and
  // `pc_now == 0xFC6B7` (the failure jump) fire on every run, passing or
  // failing: measured, `DIPSUM AA55 CHECK FAILED` printed in a run where AA55
  // was accepted and `DIPSUM SUM CHECK FAILED` printed in a run where the sum
  // was 0x500 and no repair ever ran (and an earlier cold run printed BOTH "AA55 CHECK FAILED" and "the sum
  // loop is REACHED" while the marker check was failing). The two probes that
  // answered it are below and are guest writes the ITF makes, not fetches.
  reg [31:0] dip_addr = 0;
  reg [31:0] dip_pc   = 0;
  reg        dip_is_rd = 0;
  reg        dip_pend  = 0;
  integer    dip_n     = 0;
  always @(posedge clk_sys) begin
    if (dut.memory.cpu_valid && dut.memory.cpu_ready &&
        (pc_now >= 32'h000FC66C) && (pc_now <= 32'h000FC6B6) &&
        (dut.memory.cpu_addr < 32'h0208_0000)) begin
      dip_addr  <= dut.memory.cpu_addr;
      dip_pc    <= pc_now;
      dip_is_rd <= !dut.memory.cpu_write;
      dip_pend  <= 1'b1;
      if (dut.memory.cpu_write && dip_n < 64) begin
        $display("DIPSUM wr pc=%08x addr=%08x data=%08x be=%b",
                 pc_now, dut.memory.cpu_addr, dut.memory.cpu_din,
                 dut.memory.cpu_be);
        dip_n = dip_n + 1;
      end
    end
    if (dip_pend && dip_is_rd && dut.memory.cpu_resp_valid && !dut.memory.cpu_write &&
        dip_n < 64) begin
      $display("DIPSUM rd pc=%08x addr=%08x data=%08x -> es=0x%04x off=0x%02x",
               dip_pc, dip_addr, dut.memory.cpu_dout,
               (dip_addr - dip_addr[7:0]) >> 4, dip_addr[7:0]);
      dip_n   = dip_n + 1;
      dip_pend = 1'b0;
    end
  end

  // ---- The record's verdict, from the ITF's own writes ----------------------
  // Two guest observables, both of them writes the firmware makes, neither a
  // fetch address:
  //
  //   record_repair_write -- the repair routine at 0xFC7B2 installs the record
  //     itself, and its FIRST store is byte 0xC1 into store 0x811 (row 1 of the
  //     record, BANK4@0x4924[0]); measured at cyc 271720 on a cold core and
  //     absent in every run where the record was already there.
  //     If it appears, the ITF
  //     failed the check and is re-installing the record.
  //   record_accepted -- the ITF's stage code at port 0x610 reaches 0x05. That
  //     value has exactly one writer in the whole ITF, BANK4@0x4931, reachable
  //     only from the accept branch 0xFC7AF -> 0xFC92E, so it is the firmware's
  //     own "the record passed".
  reg record_repair_write = 0;
  reg record_accepted     = 0;
  // The stage sequence itself. The 0x610 latch holds only the LAST value, so a
  // stage that is written and then overwritten is invisible after the fact; the
  // transition log is what says which phase-1/phase-2 path the boot took and
  // where it stopped. 0x610 is written by the ITF's own inline
  // `mov dx,0x610 / mov al,N / out dx,al` triple, so this is a firmware
  // observable and not a fetch address.
  reg [7:0] stage_last = 8'h00;
  reg [7:0] mode_reset_count = 8'd0;
  reg       stage_restart_seen = 1'b0;
  always @(posedge clk_sys) begin
    if (dut.iobus.dbg_itf_stage != stage_last) begin
      $display("ITFSTAGE 0x610 = %02x at cyc=%0d pc=%08x top_bank=%0d",
               dut.iobus.dbg_itf_stage, tb_cycle, pc_now, dut.iobus.top_bank);
      if (dut.iobus.dbg_itf_stage == 8'h01 && mode_reset_count != 8'd0)
        stage_restart_seen <= 1'b1;
      stage_last <= dut.iobus.dbg_itf_stage;
    end
  end
  // ---- The CPU-mode reset, instrumented at the moment it happens -----------
  // Three separate mechanisms can keep the guest out of the firmware after the
  // ITF's `out 0xF0,<n>`, so the
  // run has to say which one it was:
  //   (i)   the address of the reset-vector fetch. z486's `addr` output is the
  //         post-A20-mask physical address: the PC-98 bit-20 clear gives
  //         0xFFEFFFxx (the bios_top window), a 1 MiB wrap 0x000FFFxx;
  //   (ii)  the z486 stall state at that instant (a CPU left mid-microcode
  //         shows uc_active=1 with no bus request);
  //   (iii) the iobus FSM state, its port address and devwait (a wedged device
  //         read keeps the port address latched with devwait=1).
  // None of it is a pc_now equality: the fetch address beside them is context.
  reg reset_req_prev = 0;
  reg reset_seen = 0;
  reg [3:0] reset_fetch_n = 0;
  // The reset vector's own `ljmp 0xF800:0x4000` (BANK4@0x7FF0 = EA 00 40 00 F8)
  // sends the CPU to the ITF's phase-1 entry. That CS change is the event the
  // reset contract is about -- a fetch address alone is not, which is why the
  // boot bench's latch had to be re-gated too. Recorded after the reset request
  // so a pre-reset execution in the same bank cannot satisfy it.
  reg reset_vector_entry = 0;
  always @(posedge clk_sys) begin
    if (dut.cpu_reset_req && !reset_req_prev) begin
      mode_reset_count <= mode_reset_count + 8'd1;
      // port_c is part of the reading, not decoration: the reset class is
      // decided by the 8255 arm bits (QEMU: armed iff (sys_c & 0xa0) == 0xa0),
      // and the ITF's protected-mode entry writes 0x37 = 0x0E before LMSW 1,
      // which clears bit 7. 0x38 is the disarmed class (bit 7 clear).
      $display("MODERESET cyc=%0d pc=%08x a20=%0d top_bank=%0d port_c=%02x armed=%0d",
               tb_cycle, pc_now, dut.iobus.a20_enable, dut.iobus.top_bank,
               dut.iobus.system_port_c, (dut.iobus.system_port_c & 8'hA0) == 8'hA0);
      $display("MODERESET Z486 stall=%0d busy=%0d req=%0d accepted=%0d servicing=%0d uc_active=%0d uc_busreq=%0d",
               dut.cpu.stall, dut.cpu.mem_block_busy, dut.cpu.mem_req_current,
               dut.cpu.mem_accepted, dut.cpu.mem_servicing,
               dut.cpu.uc_active, dut.cpu.uc_busreq);
      $display("MODERESET IOBUS state=%0d addr=%04x wr=%0d be=%b valid=%0d ready=%0d flush_req=%0d devwait=%0d",
               dut.iobus.state, dut.iobus.port_addr, dut.iobus.request_write,
               dut.iobus.pending_be, dut.iobus.cpu_valid, dut.iobus.cpu_ready,
               dut.iobus.mapping_flush_required, dut.iobus.device_rd_wait);
      reset_seen <= 1'b1;
    end
    if (reset_seen && dut.z_valid && !dut.z_io && reset_fetch_n < 6) begin
      $display("RESETFETCH cyc=%0d addr=%08x wr=%0d",
               tb_cycle, {dut.z_addr, 2'b00}, dut.z_write);
      reset_fetch_n <= reset_fetch_n + 1;
    end
    if (reset_seen && (cpu_cs == 16'hF800) && (cpu_eip == 32'h0000_4000))
      reset_vector_entry <= 1'b1;
    reset_req_prev <= dut.cpu_reset_req;
  end
  // stage_0b_reached -- the ITF's `out 0x610,0x0B` at BANK4@0xFCB19 is
  //   reachable ONLY from the bit-3-clear branch of the 0x9894 test at
  //   0xFCAF3 (`je 0xfcb16`); the bit-3-set branch goes to the clock
  //   reprogram and the `out 0xF0` CPU-mode reset at 0xFCB11 and never writes
  //   this stage. So reaching 0x0B after 0x05 proves the firmware took the
  //   normal path past gate 1. This is a firmware observable -- the value the
  //   ITF writes to its own POST port -- deliberately not a PC equality (no
  //   pc_now), because a fetch address runs ahead of the write it belongs to.
  reg stage_0b_reached    = 0;
  reg stage_0b_before_05  = 0;
  // The ITF's PIT self-test at BANK4@0x038F runs immediately after stage 0x1F is
  // written and its failure is fatal: the "TIMER ERROR" message's control byte
  // has bit 7 set, and the printer turns that into `cli; jmp $` at
  // BANK4@0x01E1E7, so POST stops there and nothing downstream (the option ROM,
  // the drive byte at 0xF8E90, the IPL) is ever reached. The test needs one I/O
  // access to outlast one 2.4576 MHz PIT tick -- a property of the bus, which is
  // what pc9821_iobus's IO_ACCESS_CYCLES models and what tb_pc9821_iobus's
  // io_access_time case asserts. Stage 0x20 is the next stage the ITF writes
  // after the test, so reaching it is this bench's assertion that the test
  // passed; without it a failure here would read as "the boot has not got there
  // yet", which is exactly the wrong diagnosis.
  reg stage_1f_reached    = 0;
  reg stage_20_after_1f   = 0;
  always @(posedge clk_sys) begin
    if (dut.u_cg.cg_wr_win &&
        (dut.u_cg.cg_wr_addr == 13'h811) &&
        (dut.u_cg.cg_wr_data == 8'hC1))
      record_repair_write <= 1'b1;
    if (dut.iobus.dbg_itf_stage == 8'h05) record_accepted <= 1'b1;
    if (dut.iobus.dbg_itf_stage == 8'h1F) stage_1f_reached <= 1'b1;
    if (dut.iobus.dbg_itf_stage == 8'h20 && stage_1f_reached)
      stage_20_after_1f <= 1'b1;
    if (dut.iobus.dbg_itf_stage == 8'h0B) begin
      // Judged on the state at the moment 0x0B first appears: stage 0x05 is
      // written earlier in the same boot, so seeing 0x0B without it would mean
      // the marker is not the ITF's own order.
      if (!record_accepted && !stage_0b_reached)
        stage_0b_before_05 <= 1'b1;
      stage_0b_reached <= 1'b1;
    end
  end

  // ---- The store-level write/read pair -------------------------------------
  // The question the DIPSUM probe above cannot answer is whether the ITF's
  // configuration-record write LANDS where the check's read looks. So log the
  // responder's own store port: every commit (cg_wr_win) with the store address
  // it computed, the byte, and the window offset that produced it, then every
  // response of the same store address with the byte the responder consumed. A
  // write that mis-lands shows up as a write at one store address and a read of
  // another for the same offset; a write that lands shows the addresses equal.
  // Port 0xA9 goes through the same array (cg_ram_addr addresses u_cg_ram.ram),
  // so it is logged too, with the line register that selects its row.
  //
  // pc_now is deliberately NOT part of the correlation: it is the fetch
  // address, which runs ahead of execution, so a store write can appear under
  // a PC several bytes later. The correlation here is the store address itself.
  integer cgw_n = 0;
  integer cgr_n = 0;
  integer cga9_n = 0;
  always @(posedge clk_sys) begin
    // Window store commit: cg_wr_win is the GDC's one-cycle write strobe and
    // cg_wr_addr/cg_wr_data hold the committed address/data. base_off+byte_index
    // is the window offset the lane came from.
    if (dut.u_cg.cg_wr_win && cgw_n < 96) begin
      $display("CGW wr off=%03x st=%04x byte=%02x code=%04x lr=%0d pc=%08x",
               dut.memory.u_window.base_addr + dut.memory.u_window.byte_index,
               dut.u_cg.cg_wr_addr, dut.u_cg.cg_wr_data,
               dut.u_cg.cg_code, dut.u_cg.cg_lr, pc_now);
      cgw_n = cgw_n + 1;
    end
    // Response consumed by the window assembler; the CPU mask filters unused lanes.
    if (cg_bus_read && cgr_n < 96) begin
      $display("CGW rd off=%03x st=%04x bus=%02x code=%04x lr=%0d pc=%08x",
               cg_bus_offset, cg_bus_store, cg_bus_byte,
               dut.u_cg.cg_code, dut.u_cg.cg_lr, pc_now);
      cgr_n = cgr_n + 1;
    end
    // Port 0xA9 write: the same store, addressed by the code/line registers.
    if (dut.u_cg.cg_ram_we && cga9_n < 96) begin
      $display("CG9 wr st=%04x byte=%02x code=%04x lr=%0d line=%02x pc=%08x",
               dut.u_cg.cg_ram_addr, dut.u_cg.io_din,
               dut.u_cg.cg_code, dut.u_cg.cg_lr, dut.u_cg.cg_line,
               pc_now);
      cga9_n = cga9_n + 1;
    end
  end

  task automatic dump_cg_ram;
    integer i;
    begin
      // The store index is {code[14:8], code[0], lr, row}. Code 0x0156 (the
      // SDIP-restore source in the routine at 0x442d) lives at 0x40/0x50, and
      // code 0x2056 (what 0xFC677/0xFC69F verify) at 0x800/0x810.
      $display("BACKING CG RAM ONLY (not the static/echo bus view) code 0x0156 lr0 (0x40):");
      for (i = 0; i < 16; i = i + 1)
        $write(" %02x", dut.u_cg.u_cg_ram.ram[13'h040 + i]);
      $write("\n  lr1 (0x50):");
      for (i = 0; i < 16; i = i + 1)
        $write(" %02x", dut.u_cg.u_cg_ram.ram[13'h050 + i]);
      $write("\nBACKING CG RAM ONLY code 0x2056 lr0 (0x800):");
      for (i = 0; i < 16; i = i + 1)
        $write(" %02x", dut.u_cg.u_cg_ram.ram[13'h800 + i]);
      $write("\n  lr1 (0x810):");
      for (i = 0; i < 16; i = i + 1)
        $write(" %02x", dut.u_cg.u_cg_ram.ram[13'h810 + i]);
      $write("\n");
    end
  endtask

  // The mirror write: the ITF complements the di==5 byte and writes it to port
  // 0x31 (BANK4@0xFC6AB). It is a system port, so it never reaches device_io.
  reg io31_prev = 0;
  always @(posedge clk_sys) begin
    if (dut.z_valid && dut.z_io && dut.z_write && (dut.z_addr == 30'h31) && !io31_prev)
      $display("PORT31 W <- %02x (pc=%08x)", dut.z_dout[7:0], pc_now);
    io31_prev <= dut.z_valid && dut.z_io && dut.z_write && (dut.z_addr == 30'h31);
  end

  // The CG-RAM record and the SDIP banks are dumped the first time the fetch
  // stream reaches 0xFC7B2. The address is a FETCH address and the region is
  // entered after an ACCEPTED record too (the ITF installs its SDIP image from
  // there), so this is NOT a verdict: an earlier revision printed "ITF VERIFY
  // FAILED" here and that line appeared in a run whose record check passed with
  // no repair store at all (measured: `DIPREC cold boot: record accepted (stage
  // 0x05) = 1, repair wrote store 0x811 = 0`). Whether the ITF failed is
  // answered by the repair store and the stage code, not here.
  reg itf_dip_region_seen = 0;
  integer k;
  always @(posedge clk_sys) begin
    if (!itf_dip_region_seen && pc_now == 32'h000FC7B2) begin
      itf_dip_region_seen <= 1;
      $display("DIPREC fetched 0xFC7B2 (the record/configuration region; fetch address, not a verdict):");
      dump_cg_ram();
      for (k = 16; k >= 1; k = k - 1)
        if (pc_idx >= k) $display("    %08x", pc_hist[(pc_idx - k) % PC_HIST]);
      $display("  SDIP as stored (bank A idx0..11, then bank B idx0..11):");
      // The read is the stored byte VERBATIM (the machine returns
      // what it stored - docs/probes/RDBACK.TXT:162 reads back the even-parity
      // 0x0C it wrote), so the separate `readback` column this dump used to print
      // (sdip_read_value's odd-parity recompute, now gone from the RTL) carried the
      // same value by construction and is folded into `stored`.
      for (k = 0; k < 12; k = k + 1)
        $display("    A%02d stored=%02x", k, dut.iobus.sdip[k]);
      for (k = 0; k < 12; k = k + 1)
        $display("    B%02d stored=%02x", k, dut.iobus.sdip[12+k]);
      $display("  ctrl=0x%02x bank=%0d writable=%0d", dut.iobus.sdip_ctrl,
               dut.iobus.sdip_ctrl[6], dut.iobus.sdip_writable);
      // The ITF copies 8 KiB from D800:0000 to 9800:0000 and then checks a
      // signature inside its own shadow. If the option-ROM window was not open
      // during that copy, the shadow holds whatever was in RAM.
      $display("  ITF shadow at 0x98000 (its own copy of the option ROM):");
      for (k = 0; k < 6; k = k + 1)
        $display("    9800:%04x = %08x", k*4, ram[(32'h0009_8000 + k*4) >> 2]);
      $display("  for comparison the window source, BANK3[0:0x17] = 55 aa 2a ... at 0x09/0x0a");
    end
  end

  // ---- THE REPORTED TRIGGER: change the GDC Clock, then machine-reset three times ----
  //
  // The hardware report, verbatim (rank-1 evidence for the SYMPTOM):
  //   "On the second reset after changing the GDC setting I can get the reset software
  //   dip switch loop to come back, but further resets fix it. That is the only way
  //   I've been able to trigger it."
  //
  // +DIP_GDC_SEQ replays exactly that: boot 0 runs the authentic ITF, the OSD GDC Clock
  // field flips mid-run (an OSD menu change), then three machine resets, each boot
  // running to the destructive part of the POST (stage 1A's KANJI CG RAM test wipes the
  // record at codes 0x2056..0x7F57 - store 0x800..0x1FFF - AFTER the check, every boot,
  // by design) before the next reset. At every check pass the bench evaluates THE ITF'S
  // OWN PREDICATES over the stores the check reads (never a symptom):
  //
  //   marker  BANK4@0xFC66B-0xFC684: store 0x818/0x819 must read 0xAA/0x55
  //   sum     BANK4@0xFC68B-0xFC6AF: store 0x811..0x81A must sum to 0 mod 256
  //   parity  BANK4@0xFC6BA-0xFC726: odd parity on bank A idx 0,2,3,4,7..11 and
  //           bank B idx 0..9, the 0x89^0x8A XOR pair odd, and the idx-1 merge
  //           (p31 & 0xEF) | (presented bit 4) odd (BANK4@0xFC6CC-0xFC6DA)
  //   config  BANK4@0xFC72E-0xFC74D: skipped iff store 0x400 AND 0x401 read 0
  //
  // and records whether the repair (its first store is 0xC1 -> 0x811) and the message
  // (the string's only consumer, BANK4@0xFC8DE) ran in that boot. A gate failure at a
  // boot is what prints SET THE SOFTWARE DIP-SWITCH, so this is the predicate, not the
  // symptom. The expected values are the firmware's own (BANK4@0x4924 record table,
  // BANK4@0x480C factory DIP table) - never our RTL.
  //
  //   TB_ARGS="+DIP_GDC_SEQ" bash tests/pc9821/run_userdisk.sh <image>
  //
  // The schedule is opt-in, so no acceptance run changes. A schedule that cannot
  // complete is a $fatal (a silently-unfinished sequence must not read as green).
  reg        seq_en = 1'b0;
  integer    seq_reset_hold = 128;   // the reset window width; +SEQ_RESET_CYCLES overrides
  integer    seq_post_wipe = 45000000; // post-wipe window (the mode-reset/late-POST zone)
  integer    seq_boot = 0;           // boots COMPLETED (0 = boot 0 in progress)
  integer    seq_checks_this_boot = 0;
  integer    seq_phase = 0;          // 0 run to check, 1 run to the wipe, 2 hold reset
  integer    seq_timer = 0;
  integer    seq_reset_n = 0;
  reg        seq_msg [0:4];          // the message printed in this boot
  reg        seq_repair [0:4];       // the repair ran in this boot
  reg        seq_gates_ok [0:4];     // every gate passed at the boot's check
  reg        seq_wipe_seen = 1'b0;
  reg        seq_wipe_t0done = 1'b0;
  reg        seq_flip_done = 1'b0;
  reg        seq_stage05_prev = 1'b0;
  reg [31:0] seq_flip_at = 0;
  initial begin
    if ($test$plusargs("DIP_GDC_SEQ")) begin
      seq_en = 1'b1;
      past_ipl = 1'b1;               // the schedule owns the run length
      void'($value$plusargs("SEQ_RESET_CYCLES=%d", seq_reset_hold));
      void'($value$plusargs("SEQ_POST_WIPE=%d", seq_post_wipe));
    end
  end

  // The ITF's predicates over OBSERVED bus bytes. A missing read is NOT a seed:
  // seen masks prevent a backing-store snapshot from masquerading as a guest read.
  function automatic seq_marker_ok;
    input dummy;
    begin
      seq_marker_ok = cg_record_seen[8] && cg_record_seen[9] &&
                      (cg_record_observed[8*8 +: 8] == 8'hAA) &&
                      (cg_record_observed[9*8 +: 8] == 8'h55);
    end
  endfunction
  function automatic seq_sum_ok;
    input dummy;
    integer s, i;
    begin
      s = 0;
      for (i = 1; i <= 10; i = i + 1) s = s + cg_record_observed[i*8 +: 8];
      seq_sum_ok = (&cg_record_seen[10:1]) && ((s & 8'hFF) == 0);
    end
  endfunction
  function automatic seq_byte_odd;
    input [7:0] b;
    begin
      seq_byte_odd = ^b;
    end
  endfunction
  function automatic seq_parity_ok;
    input dummy;
    reg ok, p31_parity;
    reg [7:0] merged, presented;
    begin
      ok = 1'b1;
      // BANK4@0xFC6BA-0xFC726: the odd-parity pass and the XOR pair.
      ok = ok && seq_byte_odd(sdip_observed[0*8 +: 8]);
      ok = ok && seq_byte_odd(sdip_observed[2*8 +: 8]) && seq_byte_odd(sdip_observed[3*8 +: 8]) &&
                seq_byte_odd(sdip_observed[4*8 +: 8]);
      ok = ok && seq_byte_odd(sdip_observed[5*8 +: 8] ^ sdip_observed[6*8 +: 8]);
      ok = ok && seq_byte_odd(sdip_observed[7*8 +: 8]) && seq_byte_odd(sdip_observed[8*8 +: 8]) &&
                seq_byte_odd(sdip_observed[9*8 +: 8]) && seq_byte_odd(sdip_observed[10*8 +: 8]) &&
                seq_byte_odd(sdip_observed[11*8 +: 8]);
      ok = ok && seq_byte_odd(sdip_observed[12*8 +: 8]) && seq_byte_odd(sdip_observed[13*8 +: 8]) &&
                seq_byte_odd(sdip_observed[14*8 +: 8]) && seq_byte_odd(sdip_observed[15*8 +: 8]) &&
                seq_byte_odd(sdip_observed[16*8 +: 8]) && seq_byte_odd(sdip_observed[17*8 +: 8]) &&
                seq_byte_odd(sdip_observed[18*8 +: 8]) && seq_byte_odd(sdip_observed[19*8 +: 8]) &&
                seq_byte_odd(sdip_observed[20*8 +: 8]) && seq_byte_odd(sdip_observed[21*8 +: 8]);
      // The idx-1 merge, exactly as BANK4@0xFC6CC-0xFC6DA computes it: the port-0x851E
      // read presents bit 4 from the port-0x31 byte (pc9821_iobus.sv sdip_read_byte),
      // and the merge ORs it over the 0x31 data with bit 4 masked off.
      presented = sdip_observed[1*8 +: 8];
      merged    = (port31_observed & 8'hEF) | (presented & 8'h10);
      ok = ok && seq_byte_odd(merged);
      seq_parity_ok = ok && (&sdip_seen[11:0]) && (&sdip_seen[21:12]) && port31_seen;
    end
  endfunction
  function automatic seq_config_skipped;
    input dummy;
    begin
      seq_config_skipped = (&cg_config_seen) && (cg_config_observed == 16'h0000);
    end
  endfunction

  task automatic seq_snapshot;
    input integer boot;
    input [127:0] tag;
    reg m, s, p, c;
    integer i;
    begin
      m = seq_marker_ok(1'b0);
      s = seq_sum_ok(1'b0);
      p = seq_parity_ok(1'b0);
      c = seq_config_skipped(1'b0);
      $display("SEQ boot=%0d %0s cyc=%0d marker=%0d sum=%0d parity=%0d config_skip=%0d strap=%02x bus_seen=%04x config_seen=%x",
               boot, tag, tb_cycle, m, s, p, c, dut.iobus.dip2_reg,
               cg_record_seen, cg_config_seen);
      $write("SEQ boot=%0d observed record 810..81d:", boot);
      for (i = 0; i < 14; i = i + 1)
        if (cg_record_seen[i]) $write(" %02x", cg_record_observed[i*8 +: 8]);
        else $write(" --");
      $write("\nSEQ boot=%0d observed sdip A:", boot);
      for (i = 0; i < 12; i = i + 1)
        if (sdip_seen[i]) $write(" %02x", sdip_observed[i*8 +: 8]);
        else $write(" --");
      $write("\nSEQ boot=%0d observed sdip B:", boot);
      for (i = 12; i < 24; i = i + 1)
        if (sdip_seen[i]) $write(" %02x", sdip_observed[i*8 +: 8]);
        else $write(" --");
      $display("");
      $display("SEQ boot=%0d observed cfg gate=%04x seen=%x (unseen bytes are not a verdict)",
               boot, cg_config_observed, cg_config_seen);
      if (m && s && p && c) seq_gates_ok[boot] = 1'b1;
      else begin
        if (!m) $display("SEQ GATE FAIL boot=%0d: MARKER (BANK4@0xFC66B: 0x818/0x819 != AA/55)", boot);
        if (!s) $display("SEQ GATE FAIL boot=%0d: SUM (BANK4@0xFC68B: 0x811..0x81A sum != 0)", boot);
        if (!p) $display("SEQ GATE FAIL boot=%0d: PARITY (BANK4@0xFC6BA: a checked byte is even)", boot);
        if (!c) $display("SEQ CONFIG RESIDUAL boot=%0d: gate nonzero OR incompletely observed (seen=%x); no backing-store inference", boot, cg_config_seen);
      end
    end
  endtask

  always @(posedge clk_sys) begin
    if (seq_en) begin
      seq_stage05_prev <= (dut.iobus.dbg_itf_stage == 8'h05);
      // The OSD change: flip the live field mid-run, 2000 cycles after boot 0's
      // check has been recorded (the strap latch must not move until the next reset).
      if (!seq_flip_done && seq_phase == 1 && seq_boot == 0 && (seq_timer == 2000)) begin
        gdc_5mhz <= 1'b1;
        seq_flip_done <= 1'b1;
        $display("SEQ GDC CLOCK FLIPPED mid-run at cyc=%0d (gdc_clock_5m 0->1; strap latch moves at the next machine reset)", tb_cycle);
      end
      // The message routine: the only consumer of the string at BANK4@0x6142.
      if (pc_now == 32'h000FC8DE) begin
        seq_msg[seq_boot] <= 1'b1;
        $display("SEQ MESSAGE PRINTED in boot=%0d at cyc=%0d (BANK4@0xFC8DE)", seq_boot, tb_cycle);
      end
      // The repair's first store (BANK4@0x4924[0] = 0xC1 into record row 1).
      if (dut.u_cg.cg_wr_win && (dut.u_cg.cg_wr_addr == 13'h811) &&
          (dut.u_cg.cg_wr_data == 8'hC1)) begin
        seq_repair[seq_boot] <= 1'b1;
        $display("SEQ REPAIR RAN in boot=%0d at cyc=%0d (store 0x811 <- 0xC1)", seq_boot, tb_cycle);
      end
      // Who writes the config-gate cells and the marker cell: the two stores whose
      // content decides the next boot's gates and that the machine-reset seed does NOT
      // restore (the seed walks the record 0x810..0x81D and the mirror 0x40..0x5B).
      if (dut.u_cg.cg_wr_win &&
          ((dut.u_cg.cg_wr_addr == 13'h400) || (dut.u_cg.cg_wr_addr == 13'h401)))
        $display("SEQ CFGGATE WR st=%04x byte=%02x code=%04x lr=%0d pc=%08x cyc=%0d",
                 dut.u_cg.cg_wr_addr, dut.u_cg.cg_wr_data, dut.u_cg.cg_code,
                 dut.u_cg.cg_lr, pc_now, tb_cycle);
      // The stage-1A wipe's visit to the marker cell: a write of 0x00 to 0x818 has
      // exactly one writer in the flow (the wipe; the seed and the repair write 0xAA).
      if (dut.u_cg.cg_wr_win && (dut.u_cg.cg_wr_addr == 13'h818) &&
          (dut.u_cg.cg_wr_data == 8'h00)) begin
        seq_wipe_seen <= 1'b1;
        $display("SEQ RECORD WIPED at cyc=%0d pc=%08x (stage 1A's CG RAM test, after the check)",
                 tb_cycle, pc_now);
      end
      if (dut.iobus.sdip_seed_pulse)
        $display("SEQ SEED PULSE at cyc=%0d (machine-reset re-seed of the 24-byte DIP store + the CG record/mirror walk)", tb_cycle);

      case (seq_phase)
        0: begin  // run to the boot's check (stage 0x05 = the accept branch)
          seq_timer <= seq_timer + 1;
          if (dut.iobus.dbg_itf_stage == 8'h05 && seq_checks_this_boot == 0) begin
            seq_checks_this_boot <= 1;
            seq_snapshot(seq_boot, "CHECK");
            seq_phase <= 1;
            seq_timer <= 0;
            seq_wipe_seen <= 1'b0;
            seq_wipe_t0done <= 1'b0;
          end
          // The check FAILS: the repair is the firmware's own failure verdict.
          if (dut.u_cg.cg_wr_win && (dut.u_cg.cg_wr_addr == 13'h811) &&
              (dut.u_cg.cg_wr_data == 8'hC1) && seq_checks_this_boot == 0) begin
            seq_checks_this_boot <= 1;
            seq_snapshot(seq_boot, "CHECK-FAILED-REPAIR");
            seq_phase <= 1;
            seq_timer <= 0;
            seq_wipe_seen <= 1'b0;
            seq_wipe_t0done <= 1'b0;
          end
          if (seq_timer > 3_000_000)
            $fatal(1, "SEQ: no check in boot=%0d within 3M cycles (the ITF never reached stage 0x05 or a repair)", seq_boot);
        end
        1: begin  // run past the destructive part (the stage-1A wipe) and the whole late
                  // POST (the ITF's mode resets live there), then reset. The window counts
                  // from the WIPE, which is the event that makes a re-check dangerous.
          if (!seq_wipe_seen) begin
            seq_timer <= seq_timer + 1;
            if (seq_timer > 30_000_000)
              $fatal(1, "SEQ: the stage-1A record wipe never arrived in boot=%0d (30M cycles)", seq_boot);
          end else if (!seq_wipe_t0done) begin
            seq_wipe_t0done <= 1'b1;
            seq_timer <= 0;                 // the window's t0 is the WIPE
          end else begin
            seq_timer <= seq_timer + 1;
          end
          // A check that re-runs AFTER the wipe, within one boot, is the loop's entry:
          // the record is zeroed and the machine-reset seed is not coming. Snapshot it.
          if (seq_wipe_seen &&
              (((dut.iobus.dbg_itf_stage == 8'h05) && !seq_stage05_prev) ||
               (dut.u_cg.cg_wr_win && (dut.u_cg.cg_wr_addr == 13'h811) &&
                (dut.u_cg.cg_wr_data == 8'hC1))))
            seq_snapshot(seq_boot, "POST-WIPE-CHECK-RE-RAN");
          if (seq_wipe_seen && (seq_timer > seq_post_wipe + 32'd2000)) begin
            seq_phase <= 2;
            seq_timer <= 0;
            guest_reset <= 1'b1;
            seq_reset_n <= seq_reset_n + 1;
            $display("SEQ RESET #%0d asserted at cyc=%0d (boot=%0d done)",
                     seq_reset_n + 1, tb_cycle, seq_boot);
          end
          if (seq_timer > 30_000_000 && !seq_wipe_seen)
            $fatal(1, "SEQ: the stage-1A record wipe never arrived in boot=%0d (30M cycles)", seq_boot);
        end
        2: begin  // hold the reset, then start the next boot
          seq_timer <= seq_timer + 1;
          if (seq_timer == seq_reset_hold) begin
            guest_reset <= 1'b0;
            seq_boot <= seq_boot + 1;
            seq_checks_this_boot <= 0;
            seq_timer <= 0;
            if (seq_boot == 3) begin
              $display("SEQ: three resets done, ending at the next check (boot=%0d)", seq_boot + 1);
              seq_phase <= 3;
            end else seq_phase <= 0;
          end
        end
        3: begin  // the final boot's check, then end the schedule
          seq_timer <= seq_timer + 1;
          if (dut.iobus.dbg_itf_stage == 8'h05 && seq_checks_this_boot == 0) begin
            seq_checks_this_boot <= 1;
            seq_snapshot(seq_boot, "CHECK");
            $display("SEQ DONE: per-boot gates and repairs recorded (repairs=%0d%0d%0d%0d messages=%0d%0d%0d%0d)",
                     seq_repair[0], seq_repair[1], seq_repair[2], seq_repair[3],
                     seq_msg[0], seq_msg[1], seq_msg[2], seq_msg[3]);
            stop_now <= 1'b1;
            seq_phase <= 4;
          end
          if (seq_timer > 3_000_000)
            $fatal(1, "SEQ: no check in the final boot within 3M cycles");
        end
        default: ;
      endcase
    end
  end

  task automatic dump_sdip_history;
    integer k, p;
    begin
      $display("SDIP HISTORY (oldest first, %0d entries):", sdip_hist_n);
      for (k = 0; k < sdip_hist_n; k = k + 1) begin
        p = (sdip_hist_idx - sdip_hist_n + k + SDIP_HIST*2) % SDIP_HIST;
        if (sdip_hist_wr[p]) $display("  W %04x <- %02x", sdip_hist_addr[p], sdip_hist_data[p]);
        else                 $display("  R %04x = %02x", sdip_hist_addr[p], sdip_hist_data[p]);
      end
    end
  endtask

  task automatic dump_io_history;
    integer k, p;
    begin
      $display("IO HISTORY (oldest first, %0d entries):", io_hist_n);
      for (k = 0; k < io_hist_n; k = k + 1) begin
        p = (io_hist_idx - io_hist_n + k + IO_HIST*2) % IO_HIST;
        if (io_hist_wr[p])
          $display("  W %04x <- %02x", io_hist_addr[p], io_hist_data[p]);
        else
          $display("  R %04x", io_hist_addr[p]);
      end
    end
  endtask

  // ---- CG-window route probe ------------------------------------------------
  // The ITF's last load before the stop is `mov bl, es:0x1` at 0xA4001 through
  // the new memory-mapped CG window. Log the route's handshake a few times so an
  // accepted-but-never-answered request is distinguishable from one that
  // completed (which would leave the CPU stalled on the next instruction).
  integer cg_probe_n = 0;
  always @(posedge clk_sys) begin
    if (cg_probe_n < 16) begin
      if (dut.memory.cg_win_select && dut.cpu_mem_valid) begin
        $display("CGWIN req pc=%08x addr=%08x wr=%0d be=%b line=%0d",
                 cpu_eip, {dut.z_addr, 2'b00}, dut.z_write, dut.z_be,
                 dut.z_line_read);
        cg_probe_n = cg_probe_n + 1;
      end
      // The CG window's responder is the shared engine now (`win_*`); it is the one the CG
      // route is fed to, so its ack is the CG request's ack in this probe.
      if (dut.memory.win_cpu_ready || dut.memory.win_cpu_resp_valid) begin
        $display("CGWIN ack pc=%08x ready=%0d resp=%0d dout=%08x",
                 cpu_eip, dut.memory.win_cpu_ready,
                 dut.memory.win_cpu_resp_valid, dut.memory.win_cpu_dout);
        cg_probe_n = cg_probe_n + 1;
      end
    end
  end

  // ---- a wedged memory access, named once ----------------------------------
  // The route probe above names a CG-window request that is accepted and then
  // never answered. This is the generic form: any access the subsystem leaves
  // unready for long enough, with the address and the state of every route and
  // of the GVRAM backend engine, so an arbitration wedge and a decode hole are
  // told apart by the log instead of by a reader. The address is the point -- a
  // guest that reads a plane window through segment 0xE400 (BANK4@0x4CE8) looks
  // like a guest bug until the address is visible.
  integer wedge_cycles = 0;
  reg     wedge_reported = 0;
  always @(posedge clk_sys) begin
    if (dut.memory.cpu_valid && !dut.memory.cpu_ready && !wedge_reported) begin
      wedge_cycles = wedge_cycles + 1;
      if (wedge_cycles == 20000) begin
        wedge_reported <= 1'b1;
        // The GVRAM's own backend taps are its SDRAM D1-boundary FSM now: the 256 KiB array is
        // SDRAM-resident again (reversing the earlier move out of SDRAM into block RAM),
        // so a wedge here is the datapath FSM not completing, and the line prints its phase and
        // its D1 accept/completion (cc_*) instead.
        $display("MEMWEDGE addr=%08x wr=%b line=%b cyc=%0d | sel tram=%b open=%b cg=%b gvram=%b map=%b backend=%b | ready win=%b open=%b gvram=%b map=%b | gvram gstate=%0d cc_valid=%b cc_ready=%b cc_done=%b cpu_resp=%b line_resp=%b | loader_owns=%b",
                 dut.memory.cpu_addr, dut.memory.cpu_write, dut.memory.cpu_line_read,
                 tb_cycle, dut.memory.tram_select, dut.memory.open_select,
                 dut.memory.cg_win_select, dut.memory.gvram_select,
                 dut.memory.map_valid, dut.memory.mem_valid,
                 dut.memory.win_cpu_ready, dut.memory.open_cpu_ready,
                 dut.memory.gvram_cpu_ready,
                 dut.memory.map_cpu_ready, dut.memory.u_gvram_arb.gstate,
                 dut.memory.u_gvram_arb.cc_valid,
                 dut.memory.u_gvram_arb.cc_ready, dut.memory.u_gvram_arb.cc_done,
                 dut.memory.u_gvram_arb.cpu_resp_valid, dut.memory.u_gvram_arb.cpu_line_word_valid,
                 dut.memory.loader_owns);
        $display("MEMWEDGE2 gvram cpu_valid=%b cs=%0d owns_plain=%b owns_grcg=%b owns_egc=%b egc_gate=%b grcg_expand_gate=%b c_cl_valid=%b cc_write=%b cc_addr=%04x win_plane=%0d win_offset=%04x c_lane=%0d",
                 dut.memory.u_gvram_arb.cpu_valid, dut.memory.u_gvram_arb.cs,
                 dut.memory.u_gvram_arb.cc_owns_plain, dut.memory.u_gvram_arb.cc_owns_grcg,
                 dut.memory.u_gvram_arb.cc_owns_egc, dut.memory.u_gvram_arb.egc_gate,
                 dut.memory.u_gvram_arb.grcg_expand_gate, dut.memory.u_gvram_arb.c_cl_valid,
                 dut.memory.u_gvram_arb.cc_write, dut.memory.u_gvram_arb.cc_addr,
                 dut.memory.u_gvram_arb.win_plane, dut.memory.u_gvram_arb.win_offset,
                 dut.memory.u_gvram_arb.cc_lane_be);
        // A CPU access that no route answers for 20,000 cycles is a deadlock,
        // not patience: every responder in this tree completes in tens of
        // cycles. Failing here names the address and the owning route instead
        // of leaving the next reader with "the guest never reached the IPL"
        // twenty minutes later.
        $fatal(1, "TB_PC9821_USERDISK: FAIL (a memory access at %08x was never ready: the responder for that route is wedged and the CPU cannot make progress)",
               dut.memory.cpu_addr);
      end
    end else if (!dut.memory.cpu_valid || dut.memory.cpu_ready) begin
      wedge_cycles = 0;
    end
  end

  // ---- the RAM boundary: which route owns the byte past the end ------------
  // The ITF's memory sizing probe sits at exactly guest_ram_bytes and reports the
  // value it finds there. This core's answer at that address is a constant
  // 0xFFFF_FFFF from the absent-memory responder - which is also a perfectly
  // plausible data value - so the probe cannot tell "no memory" from "memory
  // holding all-ones", and the guest ends up in the retry loop
  // (MEMORY ERROR 0002000000 FFFFFFFF, then compare/diagnose/compare forever).
  // WHICH ROUTE answers the boundary access is what separates the two candidate
  // mechanisms, and nothing else in the log names it. Gated, so it costs nothing
  // unless asked for:
  //   TB_ARGS="+BOUNDARY_TRACE" bash tests/pc9821/run_userdisk.sh <image>
  reg bnd_trace_en = 1'b0;
  integer bnd_n = 0;
  initial begin
    if ($test$plusargs("BOUNDARY_TRACE")) bnd_trace_en = 1'b1;
  end
  always @(posedge clk_sys) begin
    if (bnd_trace_en && bnd_n < 24 &&
        dut.memory.cpu_addr >= 32'h01FF_FF00 && dut.memory.cpu_addr < 32'h0200_1000 &&
        dut.memory.cpu_valid && !dut.memory.cpu_ready) begin
      $display("BOUNDARY cyc=%0d addr=%08x wr=%b line=%b | sel tram=%b open=%b cg=%b gvram=%b map=%b | loader_owns=%b",
               tb_cycle, dut.memory.cpu_addr, dut.memory.cpu_write, dut.memory.cpu_line_read,
               dut.memory.tram_select, dut.memory.open_select,
               dut.memory.cg_win_select, dut.memory.gvram_select,
               dut.memory.map_valid, dut.memory.loader_owns);
      bnd_n = bnd_n + 1;
    end
  end

  task automatic dump_timeout_state;
    integer w, i;
    begin
      $display("TIMEOUT CPU %04x:%08x pc=%08x cyc=%0d base=%08x pe=%b", cpu_cs, cpu_eip,
               pc_now, tb_cycle, cpu_cs_base, cpu_pe);
      // RASTER (wedge diagnosis): the counters, the geometry the SYNC block decodes,
      // and the vsync/resample state the 0x60 status bit 5 reads through.
      $display("RASTER vline=%0d hdot=%0d HTOTAL=%0d VTOTAL=%0d VACTIVE=%0d VFP=%0d VSYNC_W=%0d in_vsync=%b vs_sync_ff=%b de_ff=%b gdc_start=%b pixel_ce=%b",
               dut.u_crtc.vline, dut.u_crtc.hdot, dut.u_crtc.HTOTAL, dut.u_crtc.VTOTAL,
               dut.u_crtc.VACTIVE, dut.u_crtc.VFP, dut.u_crtc.VSYNC_W,
               dut.u_crtc.in_vsync, dut.u_crtc.vs_sync_ff, dut.u_crtc.de_ff,
               dut.u_crtc.gdc_start, dut.u_crtc.pixel_ce);
      $display("RASTER sync_live=%02x%02x%02x%02x%02x%02x%02x%02x HACTIVE=%0d HS_ON=%0d HS_OFF=%0d VS_ON=%0d VS_OFF=%0d VBP=%0d",
               dut.u_crtc.sync_live[0], dut.u_crtc.sync_live[1], dut.u_crtc.sync_live[2],
               dut.u_crtc.sync_live[3], dut.u_crtc.sync_live[4], dut.u_crtc.sync_live[5],
               dut.u_crtc.sync_live[6], dut.u_crtc.sync_live[7],
               dut.u_crtc.HACTIVE, dut.u_crtc.HS_ON, dut.u_crtc.HS_OFF,
               dut.u_crtc.VS_ON, dut.u_crtc.VS_OFF, dut.u_crtc.VBP);
      // The PC tail is the single most useful thing on a stall: it names the
      // loop the guest is stuck in, which is otherwise invisible (the CS trace
      // only fires on a *segment* change, so a firmware that never leaves its
      // own segment shows nothing at all). The timer samples answer the
      // stopped-versus-looping question the change-triggered ring cannot.
      $display("CG RECORD STORES mask=%08x n818=%0d n819=%0d (bit n = a commit at store 0x800+n)",
               cg_wr_mask, cg_wr_count[5'h18], cg_wr_count[5'h19]);
      $display("MARKER CHECK boot1 reads: %02x %02x %02x %02x   boot2 reads: %02x %02x %02x %02x (reset_after_repair=%b)",
               pass1_read[0], pass1_read[1], pass1_read[2], pass1_read[3],
               chk_read[0], chk_read[1], chk_read[2], chk_read[3], did_reset);
      // The guest ends up running a 95-instruction sweep at 0x1C3-0x221 with a short
      // jump back, doing no I/O: the low 1 KiB says what that loop is and what it is
      // waiting on (IVT, BIOS data area, and the copied routine itself).
      $display("LOW RAM 0000-03FF (32 bytes per row):");
      for (integer r = 0; r < 32; r = r + 1) begin
        $write("  %04x:", r * 32);
        for (integer c = 0; c < 32; c = c + 1)
          $write(" %02x", ram[(r * 32 + c) >> 2] >> (((r * 32 + c) % 4) * 8) & 8'hFF);
        $write("\n");
      end
      dump_pc_samples;
      dump_pc_tail;
      dump_sdip_history();
      dump_io_history();
      $display("TIMEOUT IO reads=%0d writes=%0d last=%04x",
               dut.iobus.unmapped_reads, dut.iobus.unmapped_writes,
               dut.iobus.last_unmapped_port);
      // The I/O bus FSM: a CPU in an I/O wait with no port logged means the bus
      // itself never completed the access, so its state is the thing to read.
      $display("TIMEOUT IOBUS state=%0d addr=%04x wr=%0d be=%b valid=%0d ready=%0d flush_req=%0d flush_done=%0d devwait=%0d dev_rd=%0d dev_wr=%0d",
               dut.iobus.state, dut.iobus.port_addr, dut.iobus.request_write,
               dut.iobus.pending_be, dut.iobus.cpu_valid, dut.iobus.cpu_ready,
               dut.iobus.mapping_flush_required, dut.iobus.flush_done,
               dut.iobus.device_rd_wait, dut.iobus.device_io_rd,
               dut.iobus.device_io_wr);
      // The D8000 option-ROM window is gated by 0x53D bit 4 alone on this
      // non-PCI machine; 0x63C is latched for read-back only. Printing them
      // here tells us what the guest actually establishes.
      $display("GATE ide_en=%b rom_ide=%b d8=%02x top_bank=%x",
               dut.iobus.ide_rom_enable, dut.iobus.rom_gate_ide,
               dut.iobus.pci_d8_select, dut.iobus.top_bank);
      // The IDE candidate-drive byte the option ROM reads at physical 0xF8E90. Two layers
      // can answer it and WHICH one is authoritative is the question: the pack's BIOS-top
      // slot (BANK7@0x0E90, what the window shows before any gated store) and the top-window
      // SHADOW at pack + 0x100000 + 0x58000, which is what the window shows once 0x043F's 0x8
      // nibble is on and a gated store has landed. The pack's 0x0E90 byte is deliberately NOT
      // the machine's equipment byte (build_pack.py keeps BANK7's sum zero there), so reading
      // the pack here and reporting "0x00 = the ROM probes no slot" was an instrumentation
      // artefact: the byte the ROM reads is the shadow's (see DRIVEBYTE RD above).
      $display("DRIVEBYTE pack[02020E90]=%02x shadow[02158E90]=%02x (shadow is authoritative once gated)",
               ram_byte(sdram_pack_lo + 32'h0002_0000 + 32'h0E90),
               ram_byte(sdram_pack_lo + 32'h0010_0000 + 32'h0005_8000 + 32'h0E90));
      $display("TIMEOUT ATA state=%0d status=%02x error=%02x lba=%08x",
               dut.ata.xfer_state, dut.ata.status_reg, dut.ata.error_reg,
               dut.ata.current_lba);
      // idents used to print a hardcoded constant here, which made the field
      // meaningless; the identify geometry word and the divider state are the
      // values that decide whether the guest picks a 4- or 8-head geometry.
      $display("ATA dbg state=%02x cmds=%0d last=%02x aborts=%0d cyl_word=%0d cap=%0d",
               dut.ata.dbg_state, dut.ata.dbg_cmd_cnt, dut.ata.dbg_last_cmd,
               dut.ata.dbg_abort_cnt, dut.ata.current_cylinders,
               dut.ata.capacity);
      $write("IO RING (oldest first, r/w):");
      for (w = 0; w < io_ring_n; w = w + 1) begin
        i = (io_ring_idx - io_ring_n + w + 48) % 24;
        $write(" %s%04x", io_ring_wr[i] ? "w" : "r", io_ring_port[i]);
      end
      $write("\n");
      // The verdict is printed at the end of the run (the PASS marker must be
      // the last line before $finish, and the FAIL path must $fatal so the
      // runner's `set -e` sees a nonzero exit). This is a diagnostic only.
      $display("USERDISK: reached IPL = %0d", saw_ipl);
      $write("ATA CMD HISTORY (oldest first), cmd(sec_count,drv_head):");
      for (w = 0; w < ata_cmd_n; w = w + 1) begin
        i = (ata_cmd_idx - ata_cmd_n + w + 32) % 16;
        $write(" %02x(%02x,%02x)", ata_cmd_hist[i], ata_cmd_scnt[i],
               ata_cmd_head[i]);
      end
      $write("\n");
      $display("TIMEOUT RAM 04F8=%08x 04FC=%08x 0500=%08x",
               ram[24'h0004F8 >> 2], ram[24'h0004FC >> 2],
               ram[24'h000500 >> 2]);
      // Dump the IPL (1FC0:0000), the chain target (1D00:0000), and the
      // current EIP region (1D00:03C8) as dwords.
      $write("MEM 1FC00: ");
      for (w = 0; w < 16; w = w + 1)
        $write("%08x ", ram[(24'h001FC00 >> 2) + w]);
      $write("\n");
      $write("MEM 1D000: ");
      for (w = 0; w < 16; w = w + 1)
        $write("%08x ", ram[(24'h001D000 >> 2) + w]);
      $write("\n");
      $write("MEM 1D3C8: ");
      for (w = 0; w < 16; w = w + 1)
        $write("%08x ", ram[(24'h001D3C8 >> 2) + w]);
      $write("\n");
    end
  endtask
  // ==== CHECKS ====

  initial begin
    $readmemh("pc98pack.mem", pack_words);
    $readmemh("userdisk.mem", disk_words);
    repeat (10) @(posedge clk_sys);
    @(negedge clk_sys);
    reset = 0;
    ioctl_download = 1;

    for (integer i = 0; i < 16'h4000; i = i + 1)
      send_word(i * 2, pack_words[i]);
    for (integer i = 0; i < 16'hC000; i = i + 1)
      send_word(27'h0010000 + i * 2, pack_words[17'h08000 + i]);
    for (integer i = 0; i < 2048; i = i + 1)
      send_word(27'h0030000 + i * 2, pack_words[17'h18000 + i]);
    // The ROM banks behind port 0x043F: banks 0-2 in the extended area, bank 3
    // in the option-ROM slot (all 32 KiB of it -- the ITF selects bank 3 into
    // the 0xF8000 window at BANK4@0x253E, where the D8000 window only shows the
    // first 8 KiB). Banks 4-7 live in the ITF and BIOS slots loaded above.
    for (integer i = 0; i < 32'hC000; i = i + 1)
      send_word(27'h0031000 + i * 2, pack_words[17'h18800 + i]);
    for (integer i = 0; i < 32'h4000; i = i + 1)
      send_word(27'h0070000 + i * 2, pack_words[18'h38000 + i]);
    // The character generator: the whole FONT.ROM, verbatim, at pack +0x80000
    // (the 1 MiB reserve's high half). Nothing in this bench reads a glyph -- the
    // character-generator read path is a separate concern -- but the model has to
    // hold the pack the card holds, or the first bench that does read one reads
    // the result of a dropped write rather than a font.
    // EXPERIMENT: font region not sent
    // for (integer i = 0; i < 32'h23400; i = i + 1)
    //   send_word(27'h0080000 + i * 2, pack_words[18'h40000 + i]);

`ifdef LATE_MOUNT
    // The image arrives only after the guest has already started. The hardware
    // watchdog reports K=00 (the ATA never received a command write), which is
    // consistent with the guest probing the drive during ITF/BIOS startup and
    // the mount arriving later, so this variant reproduces that ordering.
    ioctl_download = 0;
    // Bounded: a pack that never loads must fail here, not at the runner's wall clock.
    begin : wait_for_pack
      integer pack_poll = 0;
      while (!debug_bios_loaded && pack_poll < 2_000_000) begin
        @(posedge clk_sys);
        pack_poll = pack_poll + 1;
      end
      if (!debug_bios_loaded)
        $fatal(1, "the ROM pack was never loaded (2M cycles)");
    end
    repeat (400_000) @(posedge clk_sys);
`else
    // Mount before the CPU is released, matching the MGL the deploy tool now
    // generates (image entry first, pack entry second). This ordering is the
    // production one, and getting it wrong was a real hardware-only failure:
    // the guest probes the drive once during startup and latches "no disk", so
    // an image listed after the pack mounts too late. Verified on hardware as
    // M=1 with K=0E X=C4 Z=02 R=12, matching this bench field for field.
`endif
    @(negedge clk_sys);
    // IMG_WORDS counts 16-bit words; img_size is bytes (block_io takes sectors as
    // img_size[40:9]).
    img_size = 64'(IMG_WORDS) * 64'd2;
    // +IMG_FILE: the drive's size is the FILE's, or the guest sees a 16 MiB disk and its
    // partition table points past the end.
    if (img_fd != 0) begin
      void'($fseek(img_fd, 0, 2));
      img_size = 64'($ftell(img_fd));
      $display("IMG_FILE size %0d bytes", img_size);
    end
    if (!$test$plusargs("NO_HDD")) begin
      img_mounted = 1'b1;
      @(negedge clk_sys);
      img_mounted = 1'b0;
    end
    if (fdd_fd != 0) begin
      repeat (2) @(negedge clk_sys);
      void'($fseek(fdd_fd, 0, 2));
      img_size = 64'($ftell(fdd_fd));
      $display("FDD_FILE size %0d bytes", img_size);
      // +FDD_RW mounts the floppy writable (writes go to fdd_ovl, never the file).
      begin : fdd_ro
        reg ro_save;
        ro_save = img_readonly;
        img_readonly = !$test$plusargs("FDD_RW");
        fdd_mounted = 1'b1;
        @(negedge clk_sys);
        fdd_mounted = 1'b0;
        img_readonly = ro_save;
      end
    end
    if (fdd2_fd != 0) begin
      repeat (2) @(negedge clk_sys);
      void'($fseek(fdd2_fd, 0, 2));
      fdd1_size = 64'($ftell(fdd2_fd));
      $display("FDD2_FILE size %0d bytes", fdd1_size);
      begin : fdd2_ro
        reg ro_save;
        ro_save = img_readonly;
        img_readonly = !$test$plusargs("FDD_RW");
        fdd1_mounted = 1'b1;
        @(negedge clk_sys);
        fdd1_mounted = 1'b0;
        img_readonly = ro_save;
      end
    end
    if (img1_fd != 0 && !cd_late) begin
      // hps_io's img_size is one register, valid for the mount that pulses: set it to the
      // second file's size for slot 3's own pulse.
      repeat (2) @(negedge clk_sys);
      void'($fseek(img1_fd, 0, 2));
      img_size = 64'($ftell(img1_fd));
      hdd1_size = img_size;
      $display("CD_FILE size %0d bytes", hdd1_size);
      hdd1_mounted = 1'b1;
      @(negedge clk_sys);
      hdd1_mounted = 1'b0;
    end

`ifndef LATE_MOUNT
    ioctl_download = 0;
    // Bounded: a pack that never loads must fail here, not at the runner's wall clock.
    begin : wait_for_pack
      integer pack_poll = 0;
      while (!debug_bios_loaded && pack_poll < 2_000_000) begin
        @(posedge clk_sys);
        pack_poll = pack_poll + 1;
      end
      if (!debug_bios_loaded)
        $fatal(1, "the ROM pack was never loaded (2M cycles)");
    end
`endif

    // +CYCLES shortens the budget for a boot trace. Measured throughput is ~330k
    // cycles/s, so the run is the whole cost of an iteration.
    begin : run_budget
      int unsigned budget = 100_000_000;
      void'($value$plusargs("CYCLES=%d", budget));
      // The measurement controls (see the declarations for the flags).
      if ($value$plusargs("STOP_AT_PC=%h", stop_pc)) stop_at_pc_valid = 1'b1;
      void'($value$plusargs("STOP_AT_PC_HITS=%d", stop_pc_hits));
      if ($value$plusargs("STOP_AT_CYCLE=%d", stop_cycle)) stop_at_cycle_valid = 1'b1;
      void'($value$plusargs("STOP_ON_STALL=%d", stop_on_stall));
      // The sim-only ARTIC override (0 = authentic). See its declaration.
      void'($value$plusargs("ARTIC_BOOST=%d", artic_boost));
        // The sim-only text-GDC vsync override (0 = authentic).
        void'($value$plusargs("VSYNC_BOOST=%d", vsync_boost));
      // +PAST_IPL is a MEASUREMENT mode, not an acceptance one: it keeps the run
      // going after 1FC0:0000 so the DOS boot and EMM386 can be exercised, and the
      // run then reports MEASURED instead of PASS/FAIL. The default acceptance run
      // still stops on saw_ipl and PASSes, unchanged.
      past_ipl = $test$plusargs("PAST_IPL") || seq_en;
      // A measurement cut at the point the answer is already known: the run
      // stops the moment the IDE option ROM reads the candidate-drive byte, so a
      // boot trace costs the hand-off (169 M) instead of the full budget.
      if ($test$plusargs("STOP_ON_DRIVEBYTE")) stop_on_drivebyte = 1'b1;
      // The calendar instrument (see its declarations): +CAL_TRACE=<cycle> arms the
      // caller/bit/buffer capture at that cycle. 0 leaves it off.
      void'($value$plusargs("CAL_TRACE=%d", cal_trace_at));
      // Stop on success: the guest reaches the IPL long before the budget ends.
      while (tb_cycle < budget && !stop_now && (!saw_ipl || past_ipl) && !stalled) @(posedge clk_sys);
      if (saw_ipl)
        $display("MEASURE reached the IPL at cyc=%0d (stopped early on success)", tb_cycle);
      if (stalled)
        $display("MEASURE stopped on a stall: pc=%08x unchanged for %0d cycles (cyc=%0d)",
                 pc_now, pc_same_cycles, tb_cycle);
      if (stop_now || stalled)
        $display("MEASURE stopped early, verdict skipped (this was a measurement run)");
      dump_tram_text;
      dump_pc_tail;
      dump_cal_trace;
      begin : fb_dump
        // +FB_PATH=<file> names the screen dump (two runs at once must not share one path).
        reg [1023:0] fb_path;
        if (!$value$plusargs("FB_PATH=%s", fb_path)) fb_path = "/tmp/pc9821_userdisk.ppm";
        dump_screen(fb_path);
      end
    end
    dump_timeout_state();
    $write("USERDISK FINAL CS:EIP=", cpu_cs, ":", cpu_eip,
           " base=", cpu_cs_base, " pe=", cpu_pe, "\n");
    // The window question, answered where it is observable: did the guest ever
    // execute in the option-ROM segment, and was the ROM there when it did?
    if (!rom_call_seen)
      $display("ROM CALL: never reached segment D800 (the boot stopped before the BIOS's option-ROM call)");
    else if (!rom_call_open)
      $display("ROM CALL: BAD -- the guest executed at pc=%08x with the 0xD8000 window CLOSED (0x053D bit 4 clear), so it ran guest RAM",
               rom_call_pc);
    else
      $display("ROM CALL: window open at pc=%08x cyc=%0d", rom_call_pc, rom_call_cycle);
    // Dump the first line of the TRAM text as a progress hint.
    $write("TRAM: ");
    for (integer i = 0; i < 80; i = i + 1)
      $write("%c", dut.u_crtc.u_text_mem.u_tram.ram[i*2]);
    $write("\n");

    // The CG-window configuration record, judged by the ITF's own writes: the
    // repair's first store must not appear, and the ITF's stage 5 (written only
    // from the accept branch) must. Both are printed either way so a run that is
    // merely a measurement still says where the record got to.
    $display("DIPREC cold boot: record accepted (stage 0x05) = %0d, repair wrote store 0x811 = %0d",
             record_accepted, record_repair_write);
    // The GDC clock, as the FIRMWARE published it: the BIOS's own derivation, read out of
    // guest low RAM rather than from any core-side register. bit 5 is the strap's direct
    // copy (BIOS.ROM@0xFD93C) and bit 2 is what the games read; with the OSD on entry 0
    // (2.5 MHz) both must be clear, and with +GDC_CLOCK_5MHZ both must be set.
    $display("GDC CLOCK work area 0000:054D = %02x (bit 5 strap copy = %0d, bit 2 games' flag = %0d, OSD 5 MHz = %0d; the machine measures 0x50, this suite's core run 0x10)",
             ram_byte(24'h00054D), ram_byte(24'h00054D)[5], ram_byte(24'h00054D)[2],
             gdc_5mhz);
    // The SAMPLED view the assertions below read, plus the ever-seen flags: printed
    // before them so a failure names which half of the chain is missing instead of
    // being read off the live byte (which is the value at the LAST cycle, not the one
    // the assertion judges).
    $display("GDC CLOCK sampled last=%02x (bit 5 = %0d, bit 2 = %0d), ever seen: bit 5 = %0d, bit 2 = %0d",
             wa54d_last, wa54d_last[5], wa54d_last[2], wa54d_b5_seen, wa54d_b2_seen);
    // THE END-TO-END CONTRACT, asserted in BOTH run postures (a short +STOP_AT_CYCLE
    // measurement must carry the answer too): the REAL BIOS derives the games' flag from
    // port 0x31 bit 7 at POST, so this is the proof that the OSD's GDC Clock field is not
    // a knob that does nothing. bit 5 is the strap's direct copy, bit 2 the games' flag;
    // both follow the OSD field. The machine's suite measured 0x50 on the Xe10 and 0x10
    // here - bits 5 and 2 clear on both, which is entry 0.
    if (wa54d_last[5] !== gdc_5mhz)
      $fatal(1, "TB_PC9821_USERDISK: FAIL (work-area 0x54D bit 5 = %0d, want %0d: the BIOS did not publish the port-0x31 GDC-clock strap at POST, so the OSD's GDC Clock field cannot reach the games)",
             wa54d_last[5], gdc_5mhz);
    if (wa54d_last[2] !== gdc_5mhz)
      $fatal(1, "TB_PC9821_USERDISK: FAIL (work-area 0x54D bit 2 = %0d, want %0d: the games' GDC-clock flag did not follow the strap, so TH03's gate and TH01's SCROLL im bit would read the wrong clock)",
             wa54d_last[2], gdc_5mhz);
    $display("GDC CLOCK ASSERTED: 0x54D bit 5 and bit 2 both follow the OSD field (5 MHz = %0d; bit 5 ever set = %0d, bit 2 ever set = %0d)",
             gdc_5mhz, wa54d_b5_seen, wa54d_b2_seen);
    $display("ITF STAGE: stage 0x0B reached after 0x05 = %0d (the 0x9894 bit-3-clear branch at 0xFCAF3)",
             stage_0b_reached && !stage_0b_before_05);
    // The CPU-mode reset, reported rather than asserted: the ITF restarts POST
    // after it, and whether it makes progress is what the stage trace above
    // says. "Restarted" means a phase-1 stage 0x01 was written again after the
    // reset, which is the ITF's own re-entry marker (BANK4@0xFC09D).
    $display("MODE RESET: requests=%0d stage sequence restarted=%0d (stage 0x01 re-written after the reset)",
             mode_reset_count, stage_restart_seen);
    $display("RESET VECTOR: re-entered F800:4000 after the out 0xF0 reset = %0d", reset_vector_entry);
  $display("PACKWATCH pack_lo=%08x pack_writes=%0d above_ram_writes=%0d sdram_top=%08x",
           sdram_pack_lo, pack_writes, above_ram_writes, sdram_top);
  // The two counts this instrument exists for. ARTICWAIT names every ARTIC wait the
  // boot entered, per home (id1..id4 above), with big-settle = the 4,840-unit calls;
  // HPS names the block-handshake latency the tiers cannot see. Under +ARTIC_BOOST
  // the ARTIC cyc columns are the model's collapsed price, not the authentic one.
  $display("ARTICWAIT entries=%0d big-settle=%0d | id1 n=%0d ticks=%0d cyc=%0d max=%0d | id2 n=%0d ticks=%0d cyc=%0d max=%0d | id3 n=%0d ticks=%0d cyc=%0d max=%0d | id4 n=%0d ticks=%0d cyc=%0d max=%0d | boost-entries=%0d | authentic-wait-cycles=%0d",
           wait_n, wait_big,
           wait_cnt[1], wait_ticks[1], wait_cost[1], wait_max[1],
           wait_cnt[2], wait_ticks[2], wait_cost[2], wait_max[2],
           wait_cnt[3], wait_ticks[3], wait_cost[3], wait_max[3],
           wait_cnt[4], wait_ticks[4], wait_cost[4], wait_max[4], artic_boost_n,
           longint'(((wait_ticks[1] + wait_ticks[2] + wait_ticks[3] + wait_ticks[4]) * 64'd4069) / 64'd25));
  $display("IDEWAIT3 BX 3386=%0d CD=%0d CC3=%0d 77D3=%0d other=%0d",
           wait_bx_3386, wait_bx_cd, wait_bx_cc3, wait_bx_77d3, wait_bx_other);
  $display("HPS reqs=%0d rd2ack avg=%0d max=%0d | ack2done avg=%0d max=%0d | total avg=%0d max=%0d cycles (model, same-cycle-ack backend)",
           hps_req_n,
           hps_req_n ? (hps_rd2ack_sum/hps_req_n) : 0, hps_rd2ack_max,
           hps_req_n ? (hps_ack2done_sum/hps_req_n) : 0, hps_ack2done_max,
           hps_req_n ? (hps_total_sum/hps_req_n) : 0, hps_total_max);

  // The acceptance verdict. This bench is the only gated proof that the
    // real image reaches the IPL, so a FAIL must fail the runner: $fatal
    // exits 1, $display+$finish exits 0 (tsb_pc9821_userdisk.sv was the one
    // bench in the suite whose verdict could not fail the gate).
    // A run that stopped early is a measurement, not an acceptance run. So is a
    // +PAST_IPL run, which by definition runs past the criterion.
    if (stop_now || stalled || past_ipl) begin
      $display("TB_PC9821_USERDISK: MEASURED (stopped early: %0s, pc=%08x held %0d cycles)",
               stalled ? "stall" : (past_ipl && saw_ipl ? "past IPL" : "by request"),
               pc_now, pc_same_cycles);
      $finish;
    end else begin
  // ==== VERDICT ====
    // The window must be open wherever the guest executes from the option-ROM
    // segment: with it closed the BIOS's `call far D800:000C` runs guest RAM,
    // so reaching segment D800 with the window shut is a wrong answer even if
    // the boot later stumbles onto the IPL.
    if (rom_call_seen && !rom_call_open)
      $fatal(1, "TB_PC9821_USERDISK: FAIL (executed in segment D800 at %08x with the option-ROM window closed)",
             rom_call_pc);
    // The record checks come before the IPL criterion on purpose: they are the
    // first gate on this boot path, and a run that fails them cannot be read as
    // "the boot has not got there yet".
    if (record_repair_write)
      $fatal(1, "TB_PC9821_USERDISK: FAIL (the ITF ran its configuration-record repair: store 0x811 <- 0xC1; the record was not present or not accepted)");
    if (!record_accepted)
      $fatal(1, "TB_PC9821_USERDISK: FAIL (the ITF never wrote stage 0x05 to port 0x610: the CG-window record was not accepted)");
    // Gate 1: the 0x9894 mode request. Stage 0x0B has one writer, the
    // bit-3-clear continuation at BANK4@0xFCB19, so a run that never reaches it
    // took the `out 0xF0` CPU-mode branch at 0xFCB11 instead.
    if (!stage_0b_reached)
      $fatal(1, "TB_PC9821_USERDISK: FAIL (the ITF never wrote stage 0x0B to port 0x610: the 0x9894 bit-3 gate diverted into the out 0xF0 CPU-mode reset at 0xFCB11)");
    if (stage_0b_before_05)
      $fatal(1, "TB_PC9821_USERDISK: FAIL (stage 0x0B appeared before stage 0x05: the 0x610 marker was not the ITF's own order)");
    // Gate 2: the ITF's port/counter walk. It is the first self-test that
    // measures the I/O bus itself, and it halts (BANK4@0x01E1E7) rather than
    // reporting, so a run that fails it stops at stage 0x1F with
    // "TIMER ERROR" on screen and would otherwise be read as "not there yet".
    if (stage_1f_reached && !stage_20_after_1f)
      $fatal(1, "TB_PC9821_USERDISK: FAIL (the ITF's PIT self-test at BANK4@0x038F failed: stage 0x20 was never written after stage 0x1F, so POST halted with TIMER ERROR at BANK4@0x01E1E7 -- one I/O access no longer outlasts one 2.4576 MHz PIT tick, see pc9821_iobus's IO_ACCESS_CYCLES)");
    // The reset's own contract, on the event not the fetch address: the vector
    // at 0x000FFFF0 is `ljmp 0xF800:0x4000`, so the CPU must come back through
    // F800:0x4000. With the wrap reverted the fetch goes to 0xFFEFFFF0 (open
    // bus) and this can never happen.
    if (!reset_vector_entry)
      $fatal(1, "TB_PC9821_USERDISK: FAIL (the out 0xF0 reset vector did not re-enter F800:0x4000: the CPU did not resume the ITF)");
    if (saw_ipl) begin
      // The old video_off / FB_FORCE_BLANK port is gone with the ao486 framebuffer shell;
      // z486_mister.sv now ties FB_FORCE_BLANK = 1'b0, so there is nothing to assert here.
      $display("VIDEO nonblack_pixels=%0d of %0d active",
               nonblack, cap_de);
      // saw_ipl proves the guest reached 1FC0:0000, not that it ran the image's bytes.
      for (integer k = 0; k < 256; k = k + 1) begin : ipl_data
        reg [31:0] want32;
        reg [31:0] got32;
        want32 = {disk_words[k*2 + 1], disk_words[k*2]};
        got32  = ram[(24'h001FC00 >> 2) + k];
        if (got32 !== want32)
          $fatal(1, "TB_PC9821_USERDISK: FAIL (IPL data at 0x%05x: image %08x, memory %08x)",
                 24'h001FC00 + k*4, want32, got32);
      end
      $display("TB_PC9821_USERDISK: PASS");
      $display("  (the two IPL sectors match the image byte for byte)");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_USERDISK: FAIL (guest never reached 1FC0:0000; longest same-PC run pc=%08x for %0d cycles, %0d of them with a microcoded instruction in flight -- nearly all of them means a LONG INSTRUCTION, near zero means a wedge)",
             pc_now, pc_same_max, pc_same_uc_max);
    end
    end // acceptance-only; $finish is not a return from this procedural block
  end

endmodule
