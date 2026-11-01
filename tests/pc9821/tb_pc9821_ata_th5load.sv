// tb_pc9821_ata_th5load - Touhou 5's text-box disk pattern, replayed through the real
// ATA engine, and the ROM's no-retry opcode stream served without aborts.
//
// ==== WHERE THE PATTERN COMES FROM (ReC98, the game's own code) ====
// A TH5 in-game text box that changes the speaker's face runs op 0x02 of the .TX2
// script (th05/main/dialog/dialog.cpp:34-50), which calls
// dialog_face_load_unput_put_free_8 (ibid. :293-340); with EMS unavailable that is
// cdg_load_single(CDG_DIALOG_FACE, faceset_fn, face_id) (th03/formats/cdg_load.cpp:27-38):
//
//   file_ropen(KAOx.CD2 / BSSx.CD2)          th05/shiftjis/fns.hpp:13-18,28
//   file_read(&cdg, sizeof(CDG))             16 bytes at file offset 0
//   file_seek(n * image_size, SEEK_CUR)
//   file_read(alpha, bitplane_size)          2,048 bytes
//   file_read(colors, 4 * bitplane_size)     8,192 bytes
//   file_close()
//
// FACE_W = FACE_H = 128 (th04/sprites/main_cdg.h:24-25), so one bitplane is
// 128/8 * 128 = 2,048 bytes and one CDG image (4 colours + alpha) is 10,240 bytes
// (th03/formats/cdg.h:22-53). The images are packed back to back after the 16-byte
// header (cdg_load.cpp:22-25 seeks n * image_size SEEK_CUR after that header read,
// i.e. from the post-header position at offset 16), so image n lives at
// file bytes [16 + n*10240, 16 + n*10240 + 10240) = disk sectors n*20 .. n*20+20:
// 21 sectors per face change, of which sector +0 and +4 are read twice (once at each
// edge of the 16-byte misalignment), i.e. 23 sectors through DOS per face. The .TX2
// speech script itself (th05/formats/dialog.cpp:9-30) is one 10-byte tx2_header_t
// read at offset 0 and one read of the playchar's slice at
// header.offset_for[playchar]. Every one of these is a DOS INT 21h call
// (libs/master.lib/file_read.asm: the AH=3Fh direct arm), so the machine's own IDE
// option ROM (D800:0018, the machine's probe results "The IDE option ROM is
// installed and owns the boot") turns each contiguous INT 1Bh read of N sectors into
// ONE READ SECTORS with count = N, one IRQ per sector and one `rep insw` of 256 words
// per sector (the IDE option ROM's disassembly, its register order). How many sectors the DOS kernel hands the BIOS per call is
// IO.SYS-internal and unmeasured, so this bench replays BOTH granularities:
//   CMD_PER_READ    one command per file_read (counts 1/5/17 per face + the singles)
//   CMD_PER_SECTOR  one count=1 command per sector (the gap-immune single-sector path)
//
// ==== THE FIX THIS BENCH FAIL-FIRSTS ====
// The ROM computes its command byte as `(flags & 0xF7) | table[class]`
// (BANK3 file 0x1085-0x10A9 = linear 0x09085-0x090A9 minus 0x8000, by the
// convention "BANKn file offset o = linear 0xD8000 + o"),
// and flags
// bit 0 is set from the INT 1Bh caller's fn bit 5 (BANK3 file 0x03B0-0x03B8:
// `test [bp+0x1],0x20 / mov ch,1 / mov es:0x2001,ch`), so a block read/write issued
// through the without-retry function variant reaches the device as opcode 0x21/0x31.
// NP2kai - the primary register-behaviour reference - serves 0x21 exactly as 0x20 and
// 0x31 exactly as 0x30 (cbus/ideio.c:902-923, `case 0x20: case 0x21:` -> readsec).
// The model previously aborted them (reason 8), and an abort is not a cheap "no":
// the ROM classifies the {ERROR,STATUS} snapshot and runs its recovery - SRST with
// ARTIC delays (file 0x0B16), RECALIBRATE (file 0x0557, which calls the settle at
// file 0x01F3), and the settle's own `delay(121*(0x28-[es:0x2060]))` ARTIC units
// (file 0x020B-0x0222) = up to 4,840 units x 833 us = 4.03 s of emulated time, the
// same pacing family earlier boot measurements found a boot walking
// into. The fail-first check is therefore the TH5 replay itself driven with the
// no-retry stream: byte-exact sectors, zero aborts, the same one-IRQ-per-sector
// cadence and the same cycle profile as the 0x20/0x30 stream.
//
// ==== WHAT IT REPORTS ====
// The TH5 pattern's latency in clk_sys and ns at 50 MHz, per command and per text box,
// with every measured cycle in one of four buckets (task-file setup + command, the
// DRQ/payload fetch wait, the PIO drain, the ISR bracket). The absolute machine target
// is capture-pending (todo item 66, a hwprobe latency capture), so the numbers are
// printed for that comparison and only the SEMANTIC checks are asserted.
//
// ==== WHAT THIS PROVES ====
// TH5's text-box access pattern - one 128x128 dialog face = 21 sectors of CDG image in three file_read-shaped reads plus a scattered directory single and a .TX2 script slice (th05/main/dialog/dialog.cpp:293 + th03/formats/cdg_load.cpp:27, faces 128x128 = 10,240 B/image, th04/sprites/main_cdg.h:24), at both BIOS command granularities (count=1 per sector, count=N per file read) - is served byte-exact with one IRQ per sector and zero aborts by BOTH opcode streams the machine's own ROM generates for it: 0x20/0x30 and the without-retry variants 0x21/0x31, whose command byte the ROM computes as (flags & 0xF7)|table[class] with flags bit 0 from the INT 1Bh caller's fn bit 5 (BANK3 file 0x03B0-0x03B8), and which NP2kai serves exactly as 0x20/0x30 (cbus/ideio.c:902-923). The two streams must cost the same cycles - an abort routes the firmware into its multi-second recovery (SRST + RECALIBRATE + the BANK3 file 0x01F3 settle of 121*(0x28-[es:0x2060]) ARTIC units = up to 4.03 s) - and the run prices the whole scene per text box and per command in clk_sys and ns at 50 MHz for the machine-target comparison.
//
// TH5's text-box access pattern - one 128x128 dialog face = 21 sectors of CDG image in
// three file_read-shaped reads plus a scattered directory single and a .TX2 script
// slice, at both BIOS command granularities - is served byte-exact with one IRQ per
// sector and zero aborts by BOTH opcode streams the machine's own ROM generates for it
// (0x20/0x30 and the fn-bit-5 without-retry variants 0x21/0x31, NP2kai ideio.c:902-923
// semantics), the two streams costing the same cycles, and the run prices the whole
// scene per text box and per command in clk_sys and ns at 50 MHz.

`timescale 1ns / 1ps

module tb_pc9821_ata_th5load;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] io_dout;
  wire block_read, block_write;
  wire [31:0] block_lba;
  wire block_done, block_error, block_buf_we;
  wire [7:0] block_buf_addr;
  wire [15:0] block_buf_data;
  wire [7:0] block_rd_addr;
  wire [15:0] block_rd_data;
  wire irq;
  wire [7:0] dbg_state;
  wire [31:0] dbg_cmd;

  wire mounted, readonly;
  wire [31:0] capacity;
  wire adapter_busy;
  wire [31:0] dbg_hps_cycles;

  wire [31:0] sd_lba;
  wire [5:0]  sd_blk_cnt;
  wire sd_rd, sd_wr;
  wire [15:0] sd_buff_din;
  reg        sd_ack = 0, sd_buff_wr = 0;
  reg [12:0] sd_buff_addr = 0;
  reg [15:0] sd_buff_dout = 0;

  reg img_mounted = 0, img_readonly = 0;
  reg [63:0] img_size = 64'd512 * 64'd100000;

  // ==== DUT ====
  pc9821_ata ata (
      // The channel's slave (device 1): no image, so the master answers for DEV=1 as before.

      .clk(clk), .rst_n(rst_n),
      .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din),
      .io_dout(io_dout),
      .mounted(mounted), .readonly(readonly), .capacity(capacity),
      .block_read(block_read), .block_write(block_write), .block_lba(block_lba),
      .block_done(block_done), .block_error(block_error),
      .block_buf_we(block_buf_we), .block_buf_addr(block_buf_addr),
      .block_buf_data(block_buf_data),
      .block_rd_addr(block_rd_addr), .block_rd_data(block_rd_data),
      .irq(irq), .dbg_state(dbg_state), .dbg_cmd(dbg_cmd)
  );

  pc9821_block_io block_io (
      .clk(clk), .rst_n(rst_n),
      .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
      .mounted(mounted), .readonly(readonly), .capacity(capacity),
      .req_read(block_read), .req_write(block_write), .req_lba(block_lba),
      // The sole owner of its engine: the window is its own, and a mount replaces the image
      // the window's blocks came from (pc9821_block_io's header).
      .req_window(1'b1), .win_flush(img_mounted),
      .req_done(block_done), .req_error(block_error),
      .buf_we(block_buf_we), .buf_addr(block_buf_addr), .buf_data(block_buf_data),
      .buf_rd_addr(block_rd_addr), .buf_rd_data(block_rd_data),
      .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt),
      .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr),
      .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
      .busy(adapter_busy),
      .dbg_hps_cycles(dbg_hps_cycles)
  );

  // ==== the HPS host model (the tb_pc9821_ata_throughput shape) ====
  // hps_lat is the request->ack round trip and word_clk the per-word stream cost. The
  // write arm presents its address one cycle ahead of the sample (the drive's read
  // port is a registered M10K) and compares every word against the synthetic map, so
  // a wrong LBA or a dropped word is a mismatch.
  integer hps_lat = 4600;   // the measured upward bound for one block round trip
  integer word_clk = 1;
  integer host_reqs = 0;
  integer host_blocks_total = 0;

  function [15:0] sector_word_for(input [31:0] lba, input [7:0] index);
    begin
      sector_word_for = {
          lba[7:0] ^ {index[6:0], 1'b1},
          lba[7:0] ^ {index[6:0], 1'b0}
      };
    end
  endfunction

  integer host_i, host_words, host_blocks, wr_errors;
  reg [31:0] host_lba;
  reg [15:0] wr_expect;

  always @(negedge clk) begin
    sd_buff_wr = 0;
    if (!sd_ack) begin
      if (sd_rd) begin
        host_lba    = sd_lba;
        host_blocks = sd_blk_cnt + 1;
        host_words  = host_blocks * 256;
        host_reqs   = host_reqs + 1;
        host_blocks_total = host_blocks_total + host_blocks;
        repeat (hps_lat) @(negedge clk);
        sd_ack = 1;
        for (host_i = 0; host_i < host_words; host_i = host_i + 1) begin
          sd_buff_wr   = 1;
          sd_buff_addr = host_i[12:0];
          sd_buff_dout = sector_word_for(host_lba + (host_i >> 8), host_i[7:0]);
          @(negedge clk);
          sd_buff_wr = 0;
          repeat (word_clk - 1) @(negedge clk);
        end
        sd_ack = 0;
      end else if (sd_wr) begin
        host_lba = sd_lba;
        host_reqs = host_reqs + 1;
        host_blocks_total = host_blocks_total + 1;
        repeat (hps_lat) @(negedge clk);
        sd_ack = 1;
        for (host_i = 0; host_i < 256; host_i = host_i + 1) begin
          sd_buff_addr = host_i[12:0];
          @(negedge clk);
          wr_expect = sector_word_for(host_lba, host_i[7:0]);
          if (sd_buff_din !== wr_expect) wr_errors = wr_errors + 1;
        end
        sd_ack = 0;
      end
    end
  end

  // ==== the scene: TH5's face loads, quantified in the header ====
  localparam [31:0] LBA_FACESET = 32'h1000;   // the faceset file's sector 0
  localparam [31:0] LBA_DIR     = 32'h0020;   // a scattered directory/FAT single
  localparam [31:0] LBA_TX2     = 32'h3000;   // the .TX2 speech script's sector 0
  localparam integer FACES = 8;               // face changes = text boxes in the scene
  localparam [7:0] TX2_SLICE_SECTORS = 8'd6;  // the playchar slice (~3 KB)

  // ==== the guest: the ROM's `insw` cadence (tb_pc9821_ata_throughput's model) ====
  localparam WORD_CYCLES = 6;
  localparam TF_CYCLES   = 5;
  localparam REP_EXTRA   = 2;
  localparam INT_CYCLES  = 60;   // ISR entry + the 0x0432 bracket + EOI/IRET

  integer errors = 0;
  // ==== CHECKS ====
  task fail(input [8*128-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  integer data_errors = 0;

  // ==== cycle accounting: every measured cycle lands in exactly one bucket ====
  localparam [1:0] P_CMD = 2'd0, P_WAIT = 2'd1, P_PIO = 2'd2, P_INT = 2'd3;
  reg [1:0] phase = P_CMD;
  reg measuring = 0;
  integer cyc_cmd = 0, cyc_wait = 0, cyc_pio = 0, cyc_int = 0, cyc_total = 0;

  always @(posedge clk) if (rst_n && measuring) begin
    cyc_total = cyc_total + 1;
    case (phase)
      P_CMD:  cyc_cmd  = cyc_cmd + 1;
      P_WAIT: cyc_wait = cyc_wait + 1;
      P_PIO:  cyc_pio  = cyc_pio + 1;
      P_INT:  cyc_int  = cyc_int + 1;
    endcase
  end

  task clear_measuring;
    begin
      cyc_cmd = 0; cyc_wait = 0; cyc_pio = 0; cyc_int = 0; cyc_total = 0;
    end
  endtask

  task lane_read(input [15:0] addr, output [7:0] data);
    begin
      phase = P_PIO;
      io_addr = addr;
      io_rd = 1;
      #1 data = io_dout;
      @(negedge clk);
      io_rd = 0;
    end
  endtask

  task tf_read(input [15:0] addr, output [7:0] data);
    begin
      io_addr = addr;
      io_rd = 1;
      #1 data = io_dout;
      @(negedge clk);
      io_rd = 0;
      repeat (TF_CYCLES - 1) @(negedge clk);
    end
  endtask

  task tf_write(input [15:0] addr, input [7:0] data);
    begin
      io_addr = addr;
      io_din = data;
      io_wr = 1;
      @(negedge clk);
      io_wr = 0;
      repeat (TF_CYCLES - 1) @(negedge clk);
    end
  endtask

  task read_pio_word(output [15:0] data);
    reg [7:0] lo, hi;
    begin
      lane_read(16'h0640, lo);
      lane_read(16'h0641, hi);
      repeat (WORD_CYCLES - 2) @(negedge clk);
      data = {hi, lo};
      repeat (REP_EXTRA) @(negedge clk);
    end
  endtask

  task write_pio_word(input [15:0] data);
    begin
      phase = P_PIO;
      tf_write(16'h0640, data[7:0]);
      tf_write(16'h0641, data[15:8]);
    end
  endtask

  task int_service;   // the ISR: the 0x0432 bracket, the 0x064E status read (the ack), EOI
    reg [7:0] status;
    begin
      phase = P_INT;
      repeat (INT_CYCLES) @(negedge clk);
      tf_read(16'h064E, status);
    end
  endtask

  // Poll 0x074C (alternate status, never acks) until DRQ. An ERR bit ends the wait at
  // once with a named failure, so a pre-fix abort is one bounded line per command and
  // not a poll timeout.
  task wait_drq;
    reg [7:0] status;
    integer n;
    begin
      n = 0;
      status = 8'h00;
      while (!status[3] && !status[0] && n < 4000) begin
        phase = P_WAIT;
        tf_read(16'h074C, status);
        n = n + 1;
      end
      if (status[0] && !status[3]) fail("command ended in ERR instead of transferring (abort)");
      else if (!status[3]) fail("DRQ timeout (the command never transferred)");
    end
  endtask

  task wait_ready;
    reg [7:0] status;
    integer n;
    begin
      n = 0;
      status = 8'hFF;
      while (status[7] && n < 4000) begin
        phase = P_WAIT;
        tf_read(16'h074C, status);
        n = n + 1;
      end
      if (status[7]) fail("BSY never cleared after a write");
    end
  endtask

  // The ROM's per-command register order: cyl lo, cyl hi,
  // drive/head, sector, count, then the opcode at 0x064E.
  task setup_command(input [7:0] count, input [31:0] lba, input [7:0] cmd);
    begin
      phase = P_CMD;
      tf_write(16'h0648, lba[15:8]);
      tf_write(16'h064A, lba[23:16]);
      tf_write(16'h064C, 8'hE0);
      tf_write(16'h0646, lba[7:0]);
      tf_write(16'h0644, count);
      tf_write(16'h064E, cmd);
    end
  endtask

  task read_sectors(input [7:0] count, input [31:0] lba, input [7:0] cmd);
    integer s, w;
    reg [15:0] word_value;
    begin
      setup_command(count, lba, cmd);
      for (s = 0; s < count; s = s + 1) begin
        wait_drq;
        int_service;
        for (w = 0; w < 256; w = w + 1) begin
          read_pio_word(word_value);
          if (word_value !== sector_word_for(lba + s, w[7:0]))
            data_errors = data_errors + 1;
        end
      end
    end
  endtask

  task write_one(input [31:0] lba, input [7:0] cmd);
    integer w;
    begin
      setup_command(8'd1, lba, cmd);
      wait_drq;
      for (w = 0; w < 256; w = w + 1)
        write_pio_word(sector_word_for(lba, w[7:0]));
      int_service;
      wait_ready;
    end
  endtask

  integer irqs_seen = 0;
  reg irq_prev = 0;
  always @(posedge clk) begin
    irq_prev <= irq;
    if (irq && !irq_prev) irqs_seen = irqs_seen + 1;
  end

  // One face change's disk pattern: the CDG header sector, the alpha read (5 sectors
  // from the 16-byte-misaligned start), the colors read (17 sectors from +4), and -
  // for every face but the first - the directory single the file_ropen pays.
  task face_load(input integer n, input [7:0] cmd, input integer per_sector);
    integer k;
    begin
      if (n > 0) read_sectors(8'd1, LBA_DIR, cmd);
      read_sectors(8'd1, LBA_FACESET, cmd);
      if (per_sector != 0) begin
        for (k = 0; k < 21; k = k + 1)
          read_sectors(8'd1, LBA_FACESET + (n * 20) + k, cmd);
      end else begin
        read_sectors(8'd5, LBA_FACESET + (n * 20), cmd);
        read_sectors(8'd17, LBA_FACESET + (n * 20) + 4, cmd);
      end
    end
  endtask

  task tx2_load(input [7:0] cmd);
    begin
      read_sectors(8'd1, LBA_TX2, cmd);
      read_sectors(TX2_SLICE_SECTORS, LBA_TX2 + 1, cmd);
    end
  endtask

  integer sectors_in_scene = 0;
  integer reqs_before = 0, blocks_before = 0, aborts_before = 0, irqs_before = 0;
  integer data_errors_before = 0;
  integer scene_reqs = 0;
  integer total_run = 0;

  // The whole dialog: FACES face changes plus one script load.
  task run_scene(input [7:0] cmd, input integer per_sector);
    integer n;
    begin
      clear_measuring;
      sectors_in_scene = (per_sector != 0) ?
          ((FACES - 1) + FACES * 22 + 1 + TX2_SLICE_SECTORS) :
          ((FACES - 1) + FACES * 23 + 1 + TX2_SLICE_SECTORS);
      reqs_before = host_reqs;
      blocks_before = host_blocks_total;
      aborts_before = dbg_cmd[31:24];
      irqs_before = irqs_seen;
      data_errors_before = data_errors;
      measuring = 1;
      for (n = 0; n < FACES; n = n + 1) face_load(n, cmd, per_sector);
      tx2_load(cmd);
      @(negedge clk);
      measuring = 0;
      total_run = cyc_total;
      scene_reqs = host_reqs - reqs_before;
    end
  endtask

  task report(input [8*16-1:0] name, input [7:0] opcode, input integer per_sector);
    integer c;
    integer kbs;
    begin
      c = cyc_total;
      // (sectors * 512 * 50000) overflows 32-bit arithmetic at this scene size;
      // scale both sides by 1000 instead (clk -> us), which cannot overflow.
      kbs = (sectors_in_scene * 512 * 50) / (c / 1000);
      $display("TH5RUN %0s opcode=%02x: cycles=%0d sectors=%0d cyc/sector=%0d ns@50MHz=%0d KB/s=%0d",
               name, opcode, c, sectors_in_scene, c / sectors_in_scene,
               c * 20, kbs);
      $display("TH5BRK %0s opcode=%02x: cmd=%0d fetch_wait=%0d pio_drain=%0d isr=%0d sum=%0d total=%0d host_reqs=%0d host_blocks=%0d irqs=%0d (want %0d) aborts=%0d",
               name, opcode, cyc_cmd, cyc_wait, cyc_pio, cyc_int,
               cyc_cmd + cyc_wait + cyc_pio + cyc_int, c,
               host_reqs - reqs_before, host_blocks_total - blocks_before,
               irqs_seen - irqs_before, sectors_in_scene, dbg_cmd[31:24] - aborts_before);
    end
  endtask

  integer total_plain, total_noretry, total_persec;

  initial begin
    wr_errors = 0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    @(negedge clk);
    img_mounted = 1;
    @(negedge clk);
    img_mounted = 0;
    while (ata.current_cylinders !== 16'd735) @(negedge clk);
    tf_write(16'h0432, 8'h00);

    // ==== the TH5 scene, command shape A: one command per file_read (0x20) ====
    run_scene(8'h20, 0);
    total_plain = total_run;
    report("cmd_per_read", 8'h20, 0);
    if (data_errors != data_errors_before) fail("TH5 scene (0x20) served wrong sector data");
    if (dbg_cmd[31:24] != aborts_before) fail("TH5 scene (0x20) aborted a command");
    if ((irqs_seen - irqs_before) != sectors_in_scene)
      fail("TH5 scene (0x20) IRQ count is not NP2kai's one-per-sector cadence");

    // ==== the same scene as the ROM's fn-bit-5 without-retry stream (0x21) ====
    // Identical bytes, identical cadence, identical cost: the pairs are one command in
    // NP2kai (ideio.c:902-923). Before the fix every 0x21 aborts and the scene never
    // transfers: this is the fail-first.
    run_scene(8'h21, 0);
    total_noretry = total_run;
    report("cmd_per_read", 8'h21, 0);
    if (dbg_cmd[31:24] != aborts_before)
      fail("0x21 (READ SECTORS without retry) aborted: NP2kai serves it as 0x20 (ideio.c:902-912)");
    if (data_errors != data_errors_before) fail("0x21 stream served wrong sector data");
    if ((irqs_seen - irqs_before) != sectors_in_scene)
      fail("0x21 stream's IRQ cadence differs from 0x20's");
    if ((total_noretry > total_plain + (total_plain / 100)) ||
        (total_noretry < total_plain - (total_plain / 100)))
      fail("0x21 and 0x20 scene costs differ: the without-retry variant is not the same command");

    // ==== command shape B: the gap-immune single-sector loop (0x20) ====
    run_scene(8'h20, 1);
    total_persec = total_run;
    report("cmd_per_sector", 8'h20, 1);
    if (data_errors != data_errors_before) fail("TH5 scene (per-sector) served wrong sector data");
    if (dbg_cmd[31:24] != aborts_before) fail("TH5 scene (per-sector) aborted a command");

    // ==== the write twin: 0x31 is 0x30 (NP2kai ideio.c:914-923) ====
    write_one(LBA_TX2 + 8, 8'h30);
    if (dbg_cmd[31:24] != aborts_before) fail("0x30 write aborted");
    aborts_before = dbg_cmd[31:24];
    write_one(LBA_TX2 + 9, 8'h31);
    if (dbg_cmd[31:24] != aborts_before)
      fail("0x31 (WRITE SECTORS without retry) aborted: NP2kai serves it as 0x30 (ideio.c:914-923)");
    if (wr_errors != 0) fail("the write stream reached the image with wrong words");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("NOTE th5load: TH5 scene = %0d face changes + one .TX2 load = up to %0d sectors, %0d host handshakes in the last scene at lat=%0d word=%0d",
               FACES, sectors_in_scene, scene_reqs, hps_lat, word_clk);
      $display("NOTE th5load: per text box (one 21-sector face change, cmd_per_read): ~%0d clk_sys = ~%0d us at 50 MHz FPGA-side",
               total_plain / FACES, (total_plain / FACES) / 50);
      $display("TB_PC9821_ATA_TH5LOAD: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_ATA_TH5LOAD: FAIL (%0d errors)", errors);
    end
  end

  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_ATA_TH5LOAD: FAIL (timeout)");
  end

endmodule
