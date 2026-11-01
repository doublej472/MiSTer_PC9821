// tb_pc9821_block_hostcost - the HOST-facing cost of a disk sector, in both directions.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_BLOCK_HOSTCOST: The host-facing cost of the disk path through the REAL stack the top level wires (pc9821_ata -> pc9821_block_share -> the shared pc9821_block_io engine) counted in the terms the ARM actually pays: HANDSHAKES per sector, 256-word transfers per sector and read-ahead window flushes, for seven realistic guest patterns (a 64-sector READ SECTORS, the DOS per-sector-command read loop, a 64-sector WRITE SECTORS, the per-sector-command write loop, an 8-page EMM386 swap pattern in both command shapes, and the per-sector read loop with a floppy read interleaved every four sectors), with a parameterised host model that charges the measured request-to-ack round trip, the ARM's per-word stream cost and -- for a write -- the FileSeek/FileWriteAdv the ARM performs AFTER its word loop (O_SYNC on the OSD's writable image, user_io.cpp:2151). It prints clk/sector, stall/sector, handshakes/sector and words/sector for every pattern, proves each sector's data is byte-exact in both directions, and pins that a sequential read stays at ~0.2 handshakes/sector, that the per-sector-command read loop keeps its read-ahead run across the EMM386 swap pattern's page writes (the bench FAILS at 24 read handshakes for 64 read sectors before that change and PASSES at 10), that a floppy read interleaved between every four disk sectors costs the disk NEITHER its read-ahead window NOR its handshake amortisation (the bench FAILS at 24 disk handshakes and 15 window losses before the window carried its image's tag, and PASSES at 6 with none), that a floppy-only sequential read is one handshake per block (the bench FAILS at 3 handshakes, 1 of them multi-block), and that the write direction is one host handshake per sector by construction - the drive's buffer holds one sector - with the ARM's own FileSeek/FileWriteAdv of the 512 bytes sitting between one handshake and the next, which the bench sweeps (wr_tail 0 / 1500 / 20000 clk) because that is the only term fewer, larger handshakes could remove. It also runs a BURST-WIDTH SWEEP: pc9821_block_io instances at BURST_SECTORS 1/2/4/8 execute the same 64-sector stream and a mid-tail pattern break under the same host model at word rates 1 and 18 clk/word (18 = 360 ns/word, the rate the 2.9 ms burst-tail claim rests on) and at a no-ARM-cache stress latency, pinning the handshake law 2 + ceil(62/width), the word law 256 x (2 + width x ceil(62/width)) and the pattern-break stall (width-1) x 256 words of tail at the word rate - the laws the width-16/32 [ESTIMATED] figures extrapolate from, because the engine width check refuses to build those.

// The central difficulty this bench exists for: NO SIMULATION CAN SEE THE HOST. The HPS
// round trip is a model here, so a bench can never say "the disk is slow" - what it CAN
// say is how many host operations (handshakes) and how many 16-bit words each guest
// pattern costs, and those are properties of the RTL. Every number this bench prints is
// meant to be compared with the hardware measurement one
// has to make (tools/hwprobe/idelat) to turn the modelled round trip into a real one.
//
// The host model is deliberately the ARM's own structure, taken from Main_MiSTer:
//   * one `sd_rd`/`sd_wr` handshake per request, carrying `sd_blk_cnt+1` blocks
//     (user_io.cpp:3247 "blks = ((c >> 9) & 0x3F) + 1;"), one poll iteration's latency
//     (`hps_lat`) before `sd_ack`, then `sd_blk_cnt+1` sectors of words at `word_clk`
//     clk_sys each -- the ARM's per-word cost is a memory write plus a strobe toggle in a
//     tight loop over the HPS-FPGA bridge (fpga_io.cpp:747 fpga_spi_fast_block_read).
//   * a read miss makes the ARM read its WHOLE 16 KiB buffer from the image
//     (user_io.cpp:3440 "FileReadAdv(&sd_image[disk], buffer[disk], sizeof(buffer[disk]))")
//     and cache 32 blocks, so the request-to-ack latency is the expensive part of a miss
//     and a hit is cheap - modelled as `hps_lat` for the first fetch of a run and
//     `hps_hit_lat` for a fetch the ARM's own 16 KiB window already covers.
//   * a write makes the ARM read the sector's 256 words into `buffer[disk]` and THEN seek
//     and write the file ("FileSeek(...); FileWriteAdv(...)"), which is what `wr_tail`
//     charges between the last word and the ack fall.

module tb_pc9821_block_hostcost;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  integer errors = 0;

  // ==== the drive: the real task file and PIO serializer, and the real shared engine ====
  reg io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] io_dout;
  wire ata_block_read, ata_block_write;
  wire [31:0] ata_block_lba;
  wire ata_block_done, ata_block_error, ata_buf_we;
  wire [7:0] ata_buf_addr;
  wire [15:0] ata_buf_data;
  wire [7:0] ata_rd_addr;
  wire [15:0] ata_rd_data;
  wire irq;
  wire [7:0] dbg_state;
  wire [31:0] dbg_cmd;

  wire hdd_mounted, hdd_readonly;
  wire [31:0] hdd_capacity;
  wire hdd_busy;
  wire [31:0] hdd_hps_cycles;

  wire [31:0] hdd_sd_lba;
  wire [5:0]  hdd_sd_blk_cnt;
  wire hdd_sd_rd, hdd_sd_wr;
  wire [15:0] hdd_sd_din;

  wire [31:0] fdd_sd_lba;
  wire [5:0]  fdd_sd_blk_cnt;
  wire fdd_sd_rd, fdd_sd_wr;
  wire [15:0] fdd_sd_din;
  wire [31:0] fdd1_sd_lba;
  wire [5:0]  fdd1_sd_blk_cnt;
  wire fdd1_sd_rd, fdd1_sd_wr;

  reg  fdd_req_read = 0;
  reg  [15:0] fdd_req_lba = 0;
  reg  fdd_req_slot = 0;
  wire fdd_req_done, fdd_req_error, fdd_busy;
  wire fdd_buf_we;
  wire [7:0] fdd_buf_addr;
  wire [15:0] fdd_buf_data;

  reg img_mounted = 0, img_readonly = 0;
  reg [63:0] img_size = 64'd512 * 64'd100000;

  reg        a_ack = 0, b_ack = 0, c_ack = 0;
  reg        sd_buff_wr = 0;
  reg [12:0] sd_buff_addr = 0;
  reg [15:0] sd_buff_dout = 0;

  // ==== DUT ====
  pc9821_ata ata (
      // The channel's slave (device 1): no image, so the master answers for DEV=1 as before.

      .clk(clk), .rst_n(rst_n),
      .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din),
      .io_dout(io_dout),
      .mounted(hdd_mounted), .readonly(hdd_readonly), .capacity(hdd_capacity),
      .block_read(ata_block_read), .block_write(ata_block_write), .block_lba(ata_block_lba),
      .block_done(ata_block_done), .block_error(ata_block_error),
      .block_buf_we(ata_buf_we), .block_buf_addr(ata_buf_addr),
      .block_buf_data(ata_buf_data),
      .block_rd_addr(ata_rd_addr), .block_rd_data(ata_rd_data),
      .irq(irq), .dbg_state(dbg_state), .dbg_cmd(dbg_cmd)
  );

  pc9821_block_share share (
      // Slot D (the second hard disk): unmounted; every disk request is for slot A.




      .clk(clk), .rst_n(rst_n),
      .a_img_mounted(img_mounted), .a_img_readonly(img_readonly), .a_img_size(img_size),
      .a_mounted(hdd_mounted), .a_readonly(hdd_readonly), .a_capacity(hdd_capacity),
      .a_req_read(ata_block_read), .a_req_write(ata_block_write), .a_req_lba(ata_block_lba),
      .a_req_window(1'b1),
      .a_req_done(ata_block_done), .a_req_error(ata_block_error), .a_busy(hdd_busy),
      .a_buf_we(ata_buf_we), .a_buf_addr(ata_buf_addr), .a_buf_data(ata_buf_data),
      .a_buf_rd_addr(ata_rd_addr), .a_buf_rd_data(ata_rd_data),
      .a_sd_lba(hdd_sd_lba), .a_sd_blk_cnt(hdd_sd_blk_cnt),
      .a_sd_rd(hdd_sd_rd), .a_sd_wr(hdd_sd_wr),
      .a_sd_ack(a_ack), .a_sd_buff_din(hdd_sd_din),
      .b_img_mounted(img_mounted), .b_img_readonly(img_readonly), .b_img_size(img_size),
      .b_req_read(fdd_req_read), .b_req_lba(fdd_req_lba), .b_req_slot(fdd_req_slot),
      .b_req_done(fdd_req_done), .b_req_error(fdd_req_error), .b_busy(fdd_busy),
      .b_buf_we(fdd_buf_we), .b_buf_addr(fdd_buf_addr), .b_buf_data(fdd_buf_data),
      .b_sd_lba(fdd_sd_lba), .b_sd_blk_cnt(fdd_sd_blk_cnt),
      .b_sd_rd(fdd_sd_rd), .b_sd_wr(fdd_sd_wr),
      .b_sd_ack(b_ack), .b_sd_buff_din(fdd_sd_din),
      .c_img_mounted(1'b0), .c_img_readonly(img_readonly), .c_img_size(64'd0),
      .c_sd_lba(fdd1_sd_lba), .c_sd_blk_cnt(fdd1_sd_blk_cnt),
      .c_sd_rd(fdd1_sd_rd), .c_sd_wr(fdd1_sd_wr),
      .c_sd_ack(c_ack), .c_sd_buff_din(),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
      .dbg_hps_cycles(hdd_hps_cycles)
  );

  // ==== the HPS host model ====
  // Word (L, i) of a sector is {L[7:0] ^ (2i+1), L[7:0] ^ (2i)}, a function of the block
  // and the word, so a stale buffer, a wrong LBA or a cross-media window hit is a data
  // mismatch rather than a silent pass.
  function [15:0] sector_word_for(input [31:0] lba, input [7:0] index);
    begin
      sector_word_for = {lba[7:0] ^ {index[6:0], 1'b1}, lba[7:0] ^ {index[6:0], 1'b0}};
    end
  endfunction

  integer hps_lat     = 4600;   // a read MISS: the ARM's poll iteration + its 16 KiB read
  integer hps_hit_lat = 200;    // a fetch the ARM's own 32-block window already covers
  integer word_clk    = 1;      // clk_sys per 16-bit word on the HPS bridge
  integer wr_tail     = 0;      // the ARM's FileSeek+FileWriteAdv after its word loop

  integer host_rd_reqs = 0, host_rd_blocks = 0, host_rd_words = 0;
  integer host_fd_reqs = 0;     // the floppy's handshakes, counted apart from the disk's
  integer fd_burst_reqs = 0;    // ... and of those, the ones that carried more than ONE block
  integer host_wr_reqs = 0, host_wr_blocks = 0, host_wr_words = 0;
  integer new_streams = 0;      // handshakes the ARM answered from the image (a miss)
  integer h_rd_bad = 0, h_wr_bad = 0;
  integer fdd_words = 0;

  // The ARM's own 32-block read window: a request inside [win_base, win_base+32) is a hit.
  reg [31:0] arm_win_base = 32'hFFFFFFFF;
  reg [5:0]  arm_win_blks = 6'd0;
  wire       arm_hit = (arm_win_blks != 6'd0) &&
                       (hdd_sd_lba >= arm_win_base) &&
                       ((hdd_sd_lba + {26'd0, hdd_sd_blk_cnt} + 32'd1 - arm_win_base) <= 32'd32);

  integer hi, hk;
  reg [31:0] h_lba;
  reg [5:0]  h_blk;
  reg [2:0]  h_state = 3'd0;     // 0 idle, 1 read stream, 2 write stream, 3 floppy read,
                                 // 4 the ARM's file work between two handshakes
  localparam H_IDLE = 3'd0, H_RD = 3'd1, H_WR = 3'd2, H_FD = 3'd3, H_WT = 3'd4;

  always @(negedge clk) begin
    sd_buff_wr = 0;
    case (h_state)
      H_IDLE: begin
        if (hdd_sd_rd) begin
          h_lba = hdd_sd_lba;
          h_blk = hdd_sd_blk_cnt;
          host_rd_reqs   = host_rd_reqs + 1;
          host_rd_blocks = host_rd_blocks + hdd_sd_blk_cnt + 1;
          if (arm_hit) begin
            repeat (hps_hit_lat) @(negedge clk);
          end else begin
            new_streams = new_streams + 1;
            repeat (hps_lat) @(negedge clk);
            arm_win_base = hdd_sd_lba;
            arm_win_blks = 6'd32;
          end
          a_ack  = 1;
          hi     = 0;
          hk     = ({26'd0, h_blk} + 32'd1) * 256;
          h_state = H_RD;
        end else if (hdd_sd_wr) begin
          h_lba = hdd_sd_lba;
          host_wr_reqs   = host_wr_reqs + 1;
          host_wr_blocks = host_wr_blocks + 1;
          repeat (hps_lat) @(negedge clk);
          a_ack   = 1;
          hi      = 0;
          h_state = H_WR;
        end else if (fdd_sd_rd) begin
          h_lba = fdd_sd_lba;
          h_blk = fdd_sd_blk_cnt;
          host_fd_reqs   = host_fd_reqs + 1;
          if (fdd_sd_blk_cnt != 6'd0) fd_burst_reqs = fd_burst_reqs + 1;
          host_rd_blocks = host_rd_blocks + fdd_sd_blk_cnt + 1;
          repeat (hps_lat) @(negedge clk);
          b_ack   = 1;
          hi      = 0;
          hk      = ({26'd0, h_blk} + 32'd1) * 256;
          h_state = H_FD;
        end
      end

      H_RD: begin
        // the ARM streams block k's 256 words at sd_buff_addr {k, word}
        if (hi < hk) begin
          sd_buff_wr   = 1;
          sd_buff_addr = hi[12:0];
          sd_buff_dout = sector_word_for(h_lba + (hi >> 8), hi[7:0]);
          host_rd_words = host_rd_words + 1;
          @(negedge clk);
          sd_buff_wr = 0;
          repeat (word_clk - 1) @(negedge clk);
          hi = hi + 1;
        end else begin
          a_ack   = 0;
          h_state = H_IDLE;
        end
      end

      H_WR: begin
        // the ARM reads the sector out of the drive's buffer at {0, word}: the address is
        // presented for a whole cycle and sampled in the middle of it, so the combinational
        // buffer read is settled
        if (hi < 256) begin
          sd_buff_addr = hi[12:0];
          host_wr_words = host_wr_words + 1;
          @(negedge clk);
          if (hdd_sd_din !== sector_word_for(h_lba, hi[7:0])) begin
            if (h_wr_bad == 0)
              $display("  FAIL: host read LBA %0d word %0d = %04x, guest wrote %04x",
                       h_lba, hi[7:0], hdd_sd_din, sector_word_for(h_lba, hi[7:0]));
            h_wr_bad = h_wr_bad + 1;
          end
          repeat (word_clk - 1) @(negedge clk);
          hi = hi + 1;
        end else begin
          // The host drops the request as soon as its word loop ends (hps_io clears sd_ack
          // when the ioctl goes inactive, and the ARM's `DisableIO()` is the instruction after
          // `spi_block_read(buffer[disk], fio_size, sz)`, Main_MiSTer/user_io.cpp:3358), and
          // only THEN seeks and writes the file. That file work runs in the same
          // single-threaded poll loop that serves the requests, so it delays the NEXT
          // handshake rather than completing this one - which is why the write direction
          // cannot be made faster in the RTL except by asking for FEWER, LARGER handshakes.
          a_ack   = 0;
          h_state = H_WT;
        end
      end

      H_WT: begin
        // the ARM's FileSeek + FileWriteAdv of this sector, before it can serve again
        repeat (wr_tail) @(negedge clk);
        h_state = H_IDLE;
      end

      default: begin
        // slot C is never requested by this bench: the floppy's two drives share port B
        if (hi < hk) begin
          sd_buff_wr   = 1;
          sd_buff_addr = hi[12:0];
          sd_buff_dout = sector_word_for(h_lba + (hi >> 8), hi[7:0]);
          @(negedge clk);
          sd_buff_wr = 0;
          repeat (word_clk - 1) @(negedge clk);
          hi = hi + 1;
        end else begin
          b_ack   = 0;
          h_state = H_IDLE;
        end
      end
    endcase
  end

  // Words the engine hands the floppy's one-block buffer (gate 2 keeps them out of the
  // drive's, and this is how the bench knows the floppy's request was really served).
  always @(posedge clk) if (fdd_buf_we) fdd_words = fdd_words + 1;

  // ==== the engine's window: what a hand-over costs it ====
  // TWO counters, because these stopped being the same event once the window carried its
  // owner's tag (T19): `meta_loads` counts the hand-over's metadata load (the share's
  // ARB_META), which is what the old hand-over DID to the window, and `win_losses` counts the
  // window itself going from live to empty, read out of the engine's own register so it means
  // the same thing on both revisions. The disk's read-ahead is destroyed exactly when the
  // second one moves - which is the thing this bench measures.
  integer meta_loads = 0;
  integer win_losses = 0;
  reg meta_prev = 0;
  reg win_live_prev = 0;
  always @(posedge clk) begin
    if (rst_n) begin
      if ((share.arb == 2'd1) && !meta_prev) meta_loads = meta_loads + 1;
      if (share.arb == 2'd1) meta_prev <= 1'b1; else meta_prev <= 1'b0;
      if (win_live_prev && (share.engine.win_total == 5'd0)) win_losses = win_losses + 1;
      win_live_prev <= (share.engine.win_total != 5'd0);
    end
  end

  // ==== THE BURST-WIDTH SWEEP (PATTERN 9) ====
  // FOUR pc9821_block_io engines, one per legal burst width, each with its own ARM host
  // model and its own stimulus (the `burstwidth_case` module below), running concurrently
  // and independently of the patterns above. The measured laws are what the report's
  // width-16/32 [ESTIMATED] figures are extrapolated from; the engine's own
  // gen_burst_width_check REFUSES to elaborate a width above 8, so those cannot be built.
  wire        bw0_done, bw1_done, bw2_done, bw8_done;
  wire [31:0] bw0_err, bw1_err, bw2_err, bw8_err;
  burstwidth_case #(.BURST_SECTORS(1)) bw0 (clk, rst_n, bw0_done, bw0_err);
  burstwidth_case #(.BURST_SECTORS(2)) bw1 (clk, rst_n, bw1_done, bw1_err);
  burstwidth_case #(.BURST_SECTORS(4)) bw2 (clk, rst_n, bw2_done, bw2_err);
  burstwidth_case #(.BURST_SECTORS(8)) bw8 (clk, rst_n, bw8_done, bw8_err);

  // ==== CHECKS ====
  task fail(input [8*128-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  integer irq_seen = 0;
  reg irq_prev = 0;
  always @(posedge clk) begin
    irq_prev <= irq;
    if (irq && !irq_prev) irq_seen = irq_seen + 1;
  end

  // The guest: the DOS driver's `insw`/`outsw` loop over the real port bytes. A 16-bit
  // word is two byte-lane strobes paced to WORD_CYCLES clk_sys (pc9821_iobus charges
  // 0x0640/0x0641 IO_MIN_HOLD = 4, tb_pc9821_ata_iowait measures 6 delivered per word),
  // a task-file access is TF_CYCLES and the ISR around the 0x064E ack is INT_CYCLES.
  localparam WORD_CYCLES = 6;
  localparam TF_CYCLES   = 5;
  localparam INT_CYCLES  = 60;

  integer run_cyc = 0, run_stall = 0;
  reg measuring = 0;
  always @(posedge clk) if (rst_n && measuring) run_cyc = run_cyc + 1;

  task lane_read(input [15:0] addr, output [7:0] data);
    begin
      io_addr = addr; io_rd = 1;
      #1 data = io_dout;
      @(negedge clk);
      io_rd = 0;
    end
  endtask

  task lane_write(input [15:0] addr, input [7:0] data);
    begin
      io_addr = addr; io_din = data; io_wr = 1;
      @(negedge clk);
      io_wr = 0;
    end
  endtask

  task tf_read(input [15:0] addr, output [7:0] data);
    begin
      io_addr = addr; io_rd = 1;
      #1 data = io_dout;
      @(negedge clk);
      io_rd = 0;
      repeat (TF_CYCLES - 1) @(negedge clk);
    end
  endtask

  task tf_write(input [15:0] addr, input [7:0] data);
    begin
      io_addr = addr; io_din = data; io_wr = 1;
      @(negedge clk);
      io_wr = 0;
      repeat (TF_CYCLES - 1) @(negedge clk);
    end
  endtask

  task wait_drq;
    reg [7:0] status;
    integer n;
    begin
      n = 0; status = 8'h00;
      while (!status[3] && n < 1000000) begin
        tf_read(16'h074C, status);
        if (!status[3]) run_stall = run_stall + TF_CYCLES;
        n = n + 1;
      end
      if (!status[3]) begin
        fail("DRQ timeout");
        $display("  state=%0d cmd=%08x status=%02x sectors_left=%0d pio_byte=%0d blkwrite=%b blkdone=%b hbusy=%0d hstate=%0d",
                 ata.xfer_state, dbg_cmd, ata.status_reg, ata.sectors_left, ata.pio_byte,
                 ata_block_write, ata_block_done, share.a_pend, h_state);
      end
    end
  endtask

  // The DOS driver's completion wait after a command's last sector: the ROM polls the
  // status until BSY clears AND DRQ drops, and only then issues the next command. Its
  // absence is not a fidelity choice - a command byte that arrives while a transfer is
  // still in flight is dropped by the device's own BSY/state guard, which is how this
  // bench first hung.
  task wait_command_end;
    reg [7:0] status;
    integer n;
    begin
      n = 0;
      status = 8'hFF;
      while ((status[7] || status[3]) && n < 100000) begin
        tf_read(16'h074C, status);
        run_stall = run_stall + TF_CYCLES;
        n = n + 1;
      end
      if (status[7] || status[3]) fail("a command never completed (BSY or DRQ stuck)");
    end
  endtask

  task int_service;
    reg [7:0] status;
    begin
      repeat (INT_CYCLES) @(negedge clk);
      tf_read(16'h064E, status);
    end
  endtask

  task setup_command(input [7:0] count, input [31:0] lba, input [7:0] cmd);
    begin
      tf_write(16'h0644, count);
      tf_write(16'h0646, lba[7:0]);
      tf_write(16'h0648, lba[15:8]);
      tf_write(16'h064A, lba[23:16]);
      tf_write(16'h064C, 8'hE0);
      tf_write(16'h064E, cmd);
    end
  endtask

  task read_sector(input [31:0] lba);
    integer w;
    reg [7:0] lo, hi;
    begin
      for (w = 0; w < 256; w = w + 1) begin
        lane_read(16'h0640, lo);
        lane_read(16'h0641, hi);
        repeat (WORD_CYCLES - 2) @(negedge clk);
        if ({hi, lo} !== sector_word_for(lba, w[7:0]))
          fail("sector data mismatch on a read");
      end
    end
  endtask

  task write_sector(input [31:0] lba);
    integer w;
    reg [15:0] v;
    begin
      for (w = 0; w < 256; w = w + 1) begin
        v = sector_word_for(lba, w[7:0]);
        lane_write(16'h0640, v[7:0]);
        lane_write(16'h0641, v[15:8]);
        repeat (WORD_CYCLES - 2) @(negedge clk);
      end
    end
  endtask

  // ==== the patterns ====
  integer p_rd_reqs, p_rd_blocks, p_wr_reqs, p_wr_blocks, p_cycles;
  integer p_meta, p_meta0, p_win, p_win0, p_fd0, p_fdb0;
  integer p_stall, p_new_streams;
  integer rd_cycle_total, wr_cycle_total;
  integer rd_cycle_n, wr_cycle_n;
  // the per-pattern figures the bounds below read (report_pattern() overwrites the p_* set)
  integer rd1_reqs, rd1_cycles, rd1_stall;
  integer rd2_reqs;
  integer raid_disk_reqs, raid_fd_reqs, raid_fd_bursts, raid_win_losses;
  integer fd8_reqs, fd8_bursts, fd8_blocks;
  integer tail_i, wr_sweep0, wr_sweep2;
  integer wr1_cycles, wr1_stall;
  integer sw6_rd_reqs, sw6_win_losses;
  integer host_wr_reqs_bounded;

  task begin_pattern;
    begin
      measuring     = 1;
      run_cyc       = 0;
      run_stall     = 0;
      p_rd_reqs     = host_rd_reqs;
      p_rd_blocks   = host_rd_blocks;
      p_wr_reqs     = host_wr_reqs;
      p_wr_blocks   = host_wr_blocks;
      p_meta0       = meta_loads;
      p_win0        = win_losses;
      p_fd0         = host_fd_reqs;
      p_fdb0        = fd_burst_reqs;
      p_new_streams = new_streams;
    end
  endtask

  task report_pattern(input [8*32-1:0] name, input integer sectors_read,
                      input integer sectors_written);
    integer hs, rs, cps, sps;
    begin
      measuring = 0;
      p_cycles  = run_cyc;
      p_stall   = run_stall;
      p_rd_reqs = host_rd_reqs - p_rd_reqs;
      p_wr_reqs = host_wr_reqs - p_wr_reqs;
      p_rd_blocks = host_rd_blocks - p_rd_blocks;
      p_wr_blocks = host_wr_blocks - p_wr_blocks;
      p_meta = meta_loads - p_meta0;
      p_win  = win_losses - p_win0;
      p_new_streams = new_streams - p_new_streams;
      hs = p_rd_reqs + p_wr_reqs;
      rs = sectors_read + sectors_written;
      cps = run_cyc / rs;
      sps = run_stall / rs;
      $display("HOSTCOST %0s: sectors=%0d cyc/sector=%0d stall/sector=%0d handshakes=%0d handshakes/sector=%0d.%02d rd_reqs=%0d rd_blocks=%0d wr_reqs=%0d words/sector=%0d meta_loads=%0d win_losses=%0d new_streams=%0d",
               name, rs, cps, sps, hs, (hs * 100) / rs / 100, (hs * 100) / rs % 100,
               p_rd_reqs, p_rd_blocks, p_wr_reqs,
               ((p_rd_blocks + p_wr_blocks) * 256) / rs, p_meta, p_win, p_new_streams);
    end
  endtask

  // A multi-sector command drained sector by sector: DRQ poll, the boundary service
  // (IRQ + 0x064E ack), then the sector's 256 words.
  task drain_read(input integer count, input [31:0] lba);
    integer s;
    begin
      for (s = 0; s < count; s = s + 1) begin
        wait_drq;
        int_service;
        read_sector(lba + s);
      end
      wait_command_end;
    end
  endtask

  task drain_write(input integer count, input [31:0] lba);
    integer s;
    begin
      for (s = 0; s < count; s = s + 1) begin
        wait_drq;
        int_service;
        write_sector(lba + s);
      end
      wait_command_end;
    end
  endtask

  // The floppy's request as pc9821_fdd_media presents it: a level held until the shared
  // adapter has it (`b_busy`), completed once, and its one block's words land on the
  // floppy's own fill port.
  task floppy_read(input [15:0] lba);
    integer k;
    begin
      fdd_req_lba  = lba;
      fdd_req_slot = 1'b0;
      @(negedge clk);
      fdd_req_read = 1'b1;
      // Hold the level until the adapter's OWN ONE-DEEP ENTRY has it (`share.b_pend`), for at
      // least one full clock. `fdd_busy` is NOT that signal: it is also high while the
      // PREVIOUS transfer still holds ownership, and releasing on it left a request whose
      // level was raised and dropped in the same time step - zero cycles wide, so the adapter
      // never saw it and this task then waited forever (it bit the floppy-only pattern, where
      // back-to-back requests meet a still-owned engine). The real pc9821_fdd_media holds
      // blk_req_rd across a full cycle in that case, because its assert and its release are
      // registered at different edges.
      @(negedge clk);
      k = 0;
      while (!share.b_pend && !fdd_req_done && k < 100000) begin @(negedge clk); k = k + 1; end
      fdd_req_read = 1'b0;
      k = 0;
      while (!fdd_req_done && k < 100000) begin @(negedge clk); k = k + 1; end
      if (!fdd_req_done) fail("the floppy's request never completed");
      @(negedge clk);
    end
  endtask

  integer sector_i, page_i;

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    @(negedge clk);
    img_mounted = 1;
    @(negedge clk);
    img_mounted = 0;
    while (ata.current_cylinders !== 16'd735) @(negedge clk);
    tf_write(16'h0432, 8'h00);
    tf_write(16'h074C, 8'h02);   // nIEN: this bench polls 0x74C/0x64E, it does not run an ISR

    $display("PATTERN 1");
    // ==== 1. one READ SECTORS, 64 sectors ====
    begin_pattern;
    setup_command(8'd64, 32'h1000, 8'h20);
    drain_read(64, 32'h1000);
    @(negedge clk);
    report_pattern("read-64-one-cmd", 64, 0);
    rd1_reqs = p_rd_reqs; rd1_cycles = p_cycles; rd1_stall = p_stall;
    rd_cycle_total = p_cycles; rd_cycle_n = 64;

    $display("PATTERN 2");
    // ==== 2. the DOS per-sector-command read loop, 32 sectors ====
    begin_pattern;
    for (sector_i = 0; sector_i < 32; sector_i = sector_i + 1) begin
      setup_command(8'd1, 32'h2000 + sector_i, 8'h20);
      drain_read(1, 32'h2000 + sector_i);
    end
    @(negedge clk);
    report_pattern("read-32-per-cmd", 32, 0);
    rd2_reqs = p_rd_reqs;

    $display("PATTERN 3");
    // ==== 3. one WRITE SECTORS, 64 sectors ====
    // `wr_tail` is the ARM's own post-stream work (FileSeek + FileWriteAdv of the sector's
    // 512 bytes, against an O_SYNC image). 1,500 clk_sys = 30 us is a DELIBERATELY MODEST
    // figure for it - an SD program cycle is orders of magnitude longer - and it is the
    // amount of that work a write completion at the ack fall puts inside the guest's stall.
    wr_tail = 1500;
    begin_pattern;
    setup_command(8'd64, 32'h3000, 8'h30);
    drain_write(64, 32'h3000);
    @(negedge clk);
    report_pattern("write-64-one-cmd", 0, 64);
    host_wr_reqs_bounded = p_wr_reqs;
    wr1_cycles = p_cycles; wr1_stall = p_stall;
    wr_cycle_total = p_cycles; wr_cycle_n = 64;

    $display("PATTERN 4");
    // ==== 4. the per-sector-command write loop, 32 sectors ====
    begin_pattern;
    for (sector_i = 0; sector_i < 32; sector_i = sector_i + 1) begin
      setup_command(8'd1, 32'h4000 + sector_i, 8'h30);
      drain_write(1, 32'h4000 + sector_i);
    end
    @(negedge clk);
    report_pattern("write-32-per-cmd", 0, 32);

    $display("PATTERN 5");
    // ==== 5. the EMM386 swap pattern: write a 4 KiB page, read the next, 8 pages ====
    begin_pattern;
    for (page_i = 0; page_i < 8; page_i = page_i + 1) begin
      setup_command(8'd8, 32'h5000 + page_i * 8, 8'h30);
      drain_write(8, 32'h5000 + page_i * 8);
      setup_command(8'd8, 32'h5000 + page_i * 8, 8'h20);
      drain_read(8, 32'h5000 + page_i * 8);
    end
    @(negedge clk);
    report_pattern("swap-8page", 64, 64);

    $display("PATTERN 6");
    // ==== 6. the same swap, one sector per command ====
    begin_pattern;
    for (page_i = 0; page_i < 8; page_i = page_i + 1) begin
      for (sector_i = 0; sector_i < 8; sector_i = sector_i + 1) begin
        setup_command(8'd1, 32'h6000 + page_i * 8 + sector_i, 8'h30);
        drain_write(1, 32'h6000 + page_i * 8 + sector_i);
      end
      for (sector_i = 0; sector_i < 8; sector_i = sector_i + 1) begin
        setup_command(8'd1, 32'h6000 + page_i * 8 + sector_i, 8'h20);
        drain_read(1, 32'h6000 + page_i * 8 + sector_i);
      end
    end
    @(negedge clk);
    report_pattern("swap-8page-per-cmd", 64, 64);
    sw6_rd_reqs = p_rd_reqs; sw6_win_losses = p_win;

    // The write direction's response to the ARM's file work: 16 single-sector write commands
    // at three `wr_tail` values, the middle one being the modest 1,500 clk the rest of the
    // bench runs at.
    for (tail_i = 0; tail_i < 3; tail_i = tail_i + 1) begin
      wr_tail = (tail_i == 0) ? 0 : (tail_i == 1) ? 1500 : 20000;
      begin_pattern;
      for (sector_i = 0; sector_i < 16; sector_i = sector_i + 1) begin
        setup_command(8'd1, 32'h9000 + sector_i, 8'h30);
        drain_write(1, 32'h9000 + sector_i);
      end
      @(negedge clk);
      measuring = 0;
      $display("WRTAIL wr_tail=%0d: %0d clk for 16 write sectors = %0d clk/sector, %0d host handshake(s)",
               wr_tail, run_cyc, run_cyc / 16, host_wr_reqs - p_wr_reqs);
      if (tail_i == 0) wr_sweep0 = -1;
      if (tail_i == 2) wr_sweep2 = run_cyc / 16;
      if (tail_i == 0) wr_sweep0 = run_cyc / 16;
    end
    wr_tail = 1500;

    $display("PATTERN 7");
    // ==== 7. the per-sector read loop with a floppy read every four sectors ====
    // The floppy reads FORWARD (blocks 2, 3, 4 ...), which is what the FDC does as it walks a
    // track: a constant LBA would hide its side of the engine's shared run detector behind a
    // request that never continues a run.
    begin_pattern;
    for (sector_i = 0; sector_i < 32; sector_i = sector_i + 1) begin
      setup_command(8'd1, 32'h7000 + sector_i, 8'h20);
      drain_read(1, 32'h7000 + sector_i);
      if ((sector_i % 4) == 3) floppy_read(16'h0002 + (sector_i >> 2));
    end
    @(negedge clk);
    report_pattern("read-32-per-cmd-floppy", 32, 0);
    // `host_rd_reqs` counts the DISK's handshakes alone (the host model adds the floppy's to
    // `host_fd_reqs` instead), so `raid_disk_reqs` needs no subtraction - the pre-fix report's
    // "16 disk handshakes" was `p_rd_reqs - host_fd_reqs`, i.e. the floppy's own 8 taken off a
    // counter that never held them. The measured pre-fix cost is 24.
    raid_disk_reqs    = p_rd_reqs;
    raid_fd_reqs      = host_fd_reqs - p_fd0;
    raid_fd_bursts    = fd_burst_reqs - p_fdb0;
    raid_win_losses   = p_win;

    $display("PATTERN 8");
    // ==== 8. the floppy's own sequential read, 8 blocks, no disk traffic ====
    // The FDC walking a track. Its side of the shared engine is pinned here - ONE handshake
    // per block (docs/trade-candidates.md T7/T8: wall clock on the floppy is traded
    // for area, bounded by the machine's own capture) - because the shared engine's burst
    // width is the DISK's, and a floppy burst is exactly what used to cost the disk its
    // window. FAIL-FIRST: while the width was shared, the run detector fired on the floppy's
    // third block and this cost 3 handshakes, two of them multi-block.
    begin_pattern;
    for (sector_i = 0; sector_i < 8; sector_i = sector_i + 1)
      floppy_read(16'h0020 + sector_i[15:0]);
    @(negedge clk);
    report_pattern("floppy-8-seq", 8, 0);
    fd8_reqs   = host_fd_reqs - p_fd0;
    fd8_bursts = fd_burst_reqs - p_fdb0;
    fd8_blocks = p_rd_blocks;

    // ==== CHECKS ====
    if (h_wr_bad != 0) begin
      $display("FAIL: %0d host-side write word(s) did not match what the guest wrote", h_wr_bad);
      errors = errors + 1;
    end
    if (host_wr_words == 0) fail("no write sector ever reached the host");
    if (fdd_words < 256) fail("the floppy's interleaved request never received its block");

    // ==== the bounds ====
    // 1. A sequential read AMORTISES the handshake: the read-ahead window carries 8 sectors
    //    per fetch, and only the two single-block fetches that earn a run are paid in full,
    //    so 64 sectors cost 2 + 8 = 10 handshakes. The bound sits well above that and well
    //    below the one-handshake-per-sector an unwindowed adapter pays, so a window that
    //    stops working - or a gate that never opens - fails here.
    $display("BOUND read-64-one-cmd: %0d handshakes for 64 sectors (%0d/sector x100)",
             rd1_reqs, (rd1_reqs * 100) / 64);
    if (rd1_reqs > 16) begin
      $display("FAIL: a 64-sector sequential read cost %0d host handshakes (bound 16, one per sector would be 64): the read-ahead window is not amortising",
               rd1_reqs);
      errors = errors + 1;
    end

    // 2. The write direction is priced against the ARM's own per-handshake work, which is NOT
    //    inside the guest's stall: the host drops the request when its word loop ends and only
    //    then seeks and writes the file, in the same single-threaded poll loop that serves the
    //    next handshake. The sweep below is that file work's cost per sector (wr_tail = one
    //    FileSeek + the FileWriteAdv of the sector's 512 bytes on an O_SYNC image): the write
    //    direction tracks it one for one, which is the measurement that says only FEWER,
    //    LARGER handshakes can make writes faster.
    // 3. The write direction is one host handshake per sector BY CONSTRUCTION - the drive's
    //    buffer holds one sector, so a multi-block write would stream N*512 bytes out of a
    //    one-sector buffer - and that count is pinned rather than bounded: 64 write sectors
    //    must cost exactly 64 handshakes. Any change that reduces it is a write-batching
    //    change and has to say what it holds unflushed (see the report's T12).
    if (host_wr_reqs_bounded != 64) begin
      $display("FAIL: one handshake per written sector expected: 64 sectors cost %0d",
               host_wr_reqs_bounded);
      errors = errors + 1;
    end
    if (wr_sweep2 <= wr_sweep0) begin
      $display("FAIL: the write direction did not scale with the host's own file work (%0d clk/sector at wr_tail=0 vs %0d at 20000): the host model is not exercising the ARM's per-handshake cost",
               wr_sweep0, wr_sweep2);
      errors = errors + 1;
    end

    // 4. The EMM386 swap pattern's READS must keep their run across the page writes that
    //    separate them: with the read run reset by a write, every 8-sector page read pays
    //    three fetches (two to earn the run, one window); with the run surviving, one or two.
    $display("BOUND swap-8page-per-cmd: %0d read handshakes for 64 read sectors (%0d/sector x100), %0d window loss(es)",
             sw6_rd_reqs, (sw6_rd_reqs * 100) / 64, sw6_win_losses);
    if (sw6_rd_reqs > 18) begin
      $display("FAIL: the swap pattern's reads cost %0d host handshakes for 64 read sectors (bound 18): the page writes are breaking the read run",
               sw6_rd_reqs);
      errors = errors + 1;
    end

    // 5. The shared engine's hand-over must not cost the disk its read-ahead. This pattern
    //    puts a floppy read between every four disk sectors, and the disk's window may not be
    //    touched by it: the disk must pay the SAME handshakes it pays with no floppy at all,
    //    and its LIVE window must never be dropped (`win_losses` reads the engine's own
    //    register, so a partially-filled window still counts). T19: before the window carried
    //    its owner's tag the hand-over flushed it at every floppy read AND the floppy's LBA
    //    polluted the disk's run, so the disk paid 24 handshakes per 32 sectors instead of 6
    //    and lost its live window 15 times.
    //    The floppy's own side is pinned too: it is served ONE block per handshake (T7/T8,
    //    whose own bench died with its own engine instance at T9 - this is that guarantee at
    //    the seat it moved to), because the FDC delivers the medium at its own rate and a
    //    burst it cannot use is what was costing the disk its window.
    $display("BOUND read-32-per-cmd-floppy: %0d DISK read handshakes for 32 sectors with a floppy read every 4 (%0d floppy handshakes, %0d of them multi-block, %0d window loss(es)) - against %0d handshakes for the same 32 sectors with no floppy (read-32-per-cmd)",
             raid_disk_reqs, raid_fd_reqs, raid_fd_bursts, raid_win_losses, rd2_reqs);
    if (raid_disk_reqs > 10) begin
      $display("FAIL: the disk cost %0d host handshakes for 32 sectors with a floppy read every 4 (bound 10; the floppy-free run is %0d): the floppy's hand-over is throwing the disk's read-ahead window away",
               raid_disk_reqs, rd2_reqs);
      errors = errors + 1;
    end
    if (raid_win_losses != 0) begin
      $display("FAIL: the disk's read-ahead window went live -> empty %0d time(s) during the interleaved pattern: the floppy's hand-over destroyed it",
               raid_win_losses);
      errors = errors + 1;
    end
    if (raid_fd_bursts != 0) begin
      $display("FAIL: %0d of the floppy's %0d handshakes carried more than one block: the floppy is served a block at a time (T7/T8), and a burst it cannot use is what costs the disk its window",
               raid_fd_bursts, raid_fd_reqs);
      errors = errors + 1;
    end

    // 6. The floppy's OWN sequential read, with no disk traffic to interleave: one handshake
    //    per block and no multi-block handshake anywhere. This is where a shared burst width
    //    shows up (the run detector fires on the floppy's third block) and where T7/T8's
    //    trade lands: 8 handshakes instead of 3 for 8 blocks, each handshake's 4,600 clk of
    //    modelled round trip hidden behind the FDC's own per-sector medium time, and the SAME
    //    2,048 words either way - the floppy does not over-fetch, it just stops asking for
    //    seven blocks it can only use after another request.
    $display("BOUND floppy-8-seq: %0d floppy handshakes for 8 blocks (%0d of them multi-block, %0d host blocks requested), %0d clk/sector in the host model",
             fd8_reqs, fd8_bursts, fd8_blocks, p_cycles / 8);
    if (fd8_reqs != 8) begin
      $display("FAIL: the floppy's sequential 8-block read cost %0d handshakes, expected one per block (8): its side of the shared engine is not one block wide any more",
               fd8_reqs);
      errors = errors + 1;
    end
    if (fd8_bursts != 0) begin
      $display("FAIL: %0d of the floppy's sequential handshakes carried more than one block (T7/T8 want sd_blk_cnt = 0 on every one of them)",
               fd8_bursts);
      errors = errors + 1;
    end

    // ==== the burst-width sweep's verdict (PATTERN 9) ====
    // Each case pins its own laws (the handshake/word arithmetic and the pattern-break
    // stall) and counts its own FAILs into `errors`; the sum keeps ONE verdict for the
    // whole file. The cases run concurrently with the patterns above and are done long
    // before this point; the wait is the contract, not the expectation.
    wait (bw0_done && bw1_done && bw2_done && bw8_done);
    errors = errors + bw0_err + bw1_err + bw2_err + bw8_err;

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_BLOCK_HOSTCOST: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_BLOCK_HOSTCOST: FAIL (%0d errors)", errors);
  end

  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_BLOCK_HOSTCOST: TIMEOUT");
  end

endmodule

// ==== THE BURST-WIDTH CASE (the sweep above instantiates four of these) ====
// One pc9821_block_io engine at ONE legal burst width, its own ARM host model and its own
// stimulus: a 64-sector sequential read stream (the cost per served sector) and a mid-tail
// pattern break (the stall a queued miss pays while a burst tail streams). It prints one
// WIDTHCOST row per word rate and one WIDTHBREAK row per word rate and counts its own
// bound FAILs into `errors`, which the tb sums into its one verdict.
//
// WHY 1/2/4/8 AND NOT 16/32: the engine's gen_burst_width_check REFUSES to elaborate a
// width above 8 (its slot decode is three bits and would alias slot k-8 onto slot k), so a
// wider case cannot be built here at all. The laws this case pins are therefore what the
// report extrapolates the width-16/32 figures from, tagged [ESTIMATED].
//
// The host model is the ARM's own structure (Main_MiSTer, ../Main_MiSTer at 915ca33): a
// 32-block (16 KiB) file window per image (user_io.cpp:3235 "static uint8_t
// buffer[16][UIO_BUFFER_SIZE];"), a FileSeek+whole-window FileReadAdv on a miss
// (user_io.cpp:3437-3442), service from the window on a hit (user_io.cpp:3492), and the
// forward refill when a served request exactly consumes the window (user_io.cpp:3506-3523)
// folded into the next request's latency. `hps_lat`/`hps_hit_lat`/`word_clk` are the same
// knobs the patterns above sweep, so every number this prints is model-side and the
// handshakes/words/stall LAWS it pins are RTL-side.
module burstwidth_case #(parameter BURST_SECTORS = 8) (
    input  wire        clk,
    input  wire        rst_n,
    output reg         done,
    output reg  [31:0] errors
);

  // ---- the engine under test: the REAL pc9821_block_io at this width ----
  reg         img_mounted = 0, img_readonly = 0;
  reg  [63:0] img_size = 64'd512 * 64'd1000000;   // 1M blocks: the phase bases reach 0x90400
  reg         req_read = 0, req_write = 0, req_window = 0;
  reg  [31:0] req_lba = 0;
  wire        req_done, req_error;
  wire        buf_we;
  wire [ 7:0] buf_addr;
  wire [15:0] buf_data;
  wire [ 7:0] buf_rd_addr;
  wire [15:0] buf_rd_data = 16'd0;
  wire [31:0] sd_lba;
  wire [ 5:0] sd_blk_cnt;
  wire        sd_rd, sd_wr;
  reg         sd_ack = 0;
  reg         sd_buff_wr = 0;
  reg  [12:0] sd_buff_addr = 0;
  reg  [15:0] sd_buff_dout = 0;
  wire [15:0] sd_buff_din;
  wire        busy;
  wire [31:0] dbg_hps_cycles;

  pc9821_block_io #(.BURST_SECTORS(BURST_SECTORS)) engine (
      .clk(clk), .rst_n(rst_n),
      .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
      .win_flush(1'b0), .mounted(), .readonly(), .capacity(),
      .req_read(req_read), .req_write(req_write), .req_lba(req_lba),
      .req_window(req_window), .req_done(req_done), .req_error(req_error),
      .buf_we(buf_we), .buf_addr(buf_addr), .buf_data(buf_data),
      .buf_rd_addr(buf_rd_addr), .buf_rd_data(buf_rd_data),
      .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_wr(sd_wr),
      .sd_ack(sd_ack), .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr),
      .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
      .busy(busy), .dbg_hps_cycles(dbg_hps_cycles)
  );

  function [15:0] sector_word_for(input [31:0] lba, input [7:0] index);
    begin
      sector_word_for = {lba[7:0] ^ {index[6:0], 1'b1}, lba[7:0] ^ {index[6:0], 1'b0}};
    end
  endfunction

  // ---- the ARM host model ----
  integer hps_lat     = 4600;   // a read MISS: the poll iteration + the ARM's file seek/read
  integer hps_hit_lat = 200;    // a fetch inside the ARM's own 32-block window
  integer word_clk    = 1;      // clk_sys per 16-bit word on the HPS bridge

  integer host_reqs = 0, host_words = 0, host_misses = 0;
  integer ack_cyc_max = 0;

  reg [31:0] arm_win_base = 32'hFFFFFFFF;
  reg [31:0] arm_win_blks = 32'd0;

  integer hi, hk, h_blkc, ack_len;
  reg [31:0] h_lba;

  initial begin
    forever begin
      @(negedge clk);
      if (rst_n && sd_rd) begin
        h_lba  = sd_lba;
        h_blkc = {26'd0, sd_blk_cnt} + 32'd1;
        host_reqs  = host_reqs + 1;
        host_words = host_words + h_blkc * 256;
        if ((arm_win_blks == 32'd0) || (h_lba < arm_win_base) ||
            ((h_lba + h_blkc - arm_win_base) > 32'd32)) begin
          host_misses = host_misses + 1;
          repeat (hps_lat) @(negedge clk);
          arm_win_base = h_lba;
          arm_win_blks = 32'd32;
        end else begin
          repeat (hps_hit_lat) @(negedge clk);
        end
        sd_ack  = 1;
        ack_len = 0;
        hk      = h_blkc * 256;
        for (hi = 0; hi < hk; hi = hi + 1) begin
          sd_buff_wr   = 1;
          sd_buff_addr = hi[12:0];
          sd_buff_dout = sector_word_for(h_lba + (hi >> 8), hi[7:0]);
          @(negedge clk);
          sd_buff_wr = 0;
          repeat (word_clk - 1) @(negedge clk);
          ack_len = ack_len + 1;
        end
        sd_ack = 0;
        if (ack_len > ack_cyc_max) ack_cyc_max = ack_len;
        // the ARM's forward refill when this request exactly consumed its window
        // (user_io.cpp:3506-3523): its file work is folded into the next miss's latency
        if ((h_lba + h_blkc - arm_win_base) == 32'd32) arm_win_base = h_lba + h_blkc;
      end
    end
  end

  // ---- the stimulus ----
  integer cyc = 0;
  always @(posedge clk) cyc = cyc + 1;

  integer t0, t1, last_cost;

  // One read request at the engine's own contract (a pulse, accepted with no serve owed),
  // costed accept -> completion exactly as the guest waits behind it.
  task do_read(input [31:0] lba, output integer cost);
    begin
      req_lba    = lba;
      req_window = 1'b1;
      req_read   = 1'b1;
      @(negedge clk);
      req_read = 1'b0;
      t0 = cyc;
      while (!req_done) @(negedge clk);
      t1   = cyc;
      cost = t1 - t0;
    end
  endtask

  integer stream_hs0, stream_w0, stream_m0, stream_hs, stream_w, stream_m;
  integer stream_start, stream_end, stream_cyc;
  integer expect_bursts, expect_hs, expect_words;

  task run_stream(input [31:0] base);
    integer s, cost;
    begin
      stream_hs0 = host_reqs; stream_w0 = host_words; stream_m0 = host_misses;
      stream_start = cyc;
      for (s = 0; s < 64; s = s + 1) do_read(base + s, cost);
      stream_end = cyc;
      stream_cyc = stream_end - stream_start;
      stream_hs  = host_reqs - stream_hs0;
      stream_w   = host_words - stream_w0;
      stream_m   = host_misses - stream_m0;
      // the pinned laws: the run detector opens at the THIRD contiguous request and every
      // later request of the run is served from the window, so a 64-sector stream costs
      // two single-block fetches plus ceil(62/WIDTH) bursts of WIDTH blocks each.
      expect_bursts = (62 + BURST_SECTORS - 1) / BURST_SECTORS;
      expect_hs     = 2 + expect_bursts;
      expect_words  = 256 * (2 + BURST_SECTORS * expect_bursts);
      $display("WIDTHCOST w=%0d word=%0d hit=%0d: sectors=64 handshakes=%0d misses=%0d words=%0d cyc=%0d cyc_per_sector=%0d ack_cyc_max=%0d",
               BURST_SECTORS, word_clk, hps_hit_lat, stream_hs, stream_m, stream_w,
               stream_cyc, stream_cyc / 64, ack_cyc_max);
      if (stream_hs != expect_hs) begin
        $display("FAIL: w=%0d word=%0d: %0d host handshakes for a 64-sector sequential stream, the pinned law 2 + ceil(62/%0d) = %0d",
                 BURST_SECTORS, word_clk, stream_hs, BURST_SECTORS, expect_hs);
        errors = errors + 1;
      end
      if (stream_w != expect_words) begin
        $display("FAIL: w=%0d word=%0d: %0d words streamed for a 64-sector sequential stream, the pinned law 256 x (2 + %0d x %0d) = %0d",
                 BURST_SECTORS, word_clk, stream_w, BURST_SECTORS, expect_bursts, expect_words);
        errors = errors + 1;
      end
    end
  endtask

  integer brk_cost, idle_cost, tail_meas, expect_tail;

  // The pattern break: the run opens (two singles plus one burst), the burst's SLOT 0
  // completes, and the guest immediately asks for a far LBA the window does not hold - the
  // worst alignment, because the whole background tail is still streaming. The queued miss
  // waits for the fetch engine to go idle and only then takes its own handshake (the
  // engine's S_WAIT arm: `else if (!fetch_active)`). The control is the same far-class
  // request with the engine idle, so tail = break - idle is pure queueing.
  task run_break(input [31:0] base, input [31:0] far1, input [31:0] far2);
    integer cost;
    begin
      do_read(base + 0, cost);
      do_read(base + 1, cost);
      do_read(base + 2, cost);
      do_read(far1, brk_cost);
      while (busy) @(negedge clk);
      repeat (8) @(negedge clk);
      do_read(far2, idle_cost);
      while (busy) @(negedge clk);
      tail_meas   = brk_cost - idle_cost;
      expect_tail = (BURST_SECTORS - 1) * 256 * word_clk;
      $display("WIDTHBREAK w=%0d word=%0d: break_cyc=%0d idle_cyc=%0d tail=%0d expect_tail=%0d",
               BURST_SECTORS, word_clk, brk_cost, idle_cost, tail_meas, expect_tail);
      // The stall is the tail's remaining words at the host's word rate plus a few cycles
      // of fetch-engine hand-over (the bounds below allow the +-), and NOTHING else: a
      // request that starts paying double, or that stops queueing behind the tail at all
      // (tail ~ 0 at a width above 1), fails here.
      if ((tail_meas < expect_tail - 4) || (tail_meas > expect_tail + 40)) begin
        $display("FAIL: w=%0d word=%0d: the pattern-break stall is %0d clk, outside the pinned law (W-1) x 256 words x word_clk = %0d (+-40)",
                 BURST_SECTORS, word_clk, tail_meas, expect_tail);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    done   = 1'b0;
    errors = 32'd0;
    wait (rst_n === 1'b1);
    @(negedge clk);
    img_mounted = 1;
    @(negedge clk);
    img_mounted = 0;
    @(negedge clk);

    // A/B: the stream at the ideal word rate and at 360 ns/word (18 clk at 50 MHz), both
    // with the ARM's window hit priced at the model's 200 clk.
    word_clk = 1;  hps_lat = 4600; hps_hit_lat = 200;
    run_stream(32'h10000);
    word_clk = 18; hps_lat = 4600; hps_hit_lat = 200;
    run_stream(32'h20000);
    // C: the stress bound - every handshake charged the full measured ~4600-clk residual (the ARM
    // window model off), which is the assumption the width-32 win arithmetic used.
    word_clk = 18; hps_lat = 4600; hps_hit_lat = 4600;
    run_stream(32'h30000);
    // D/E: the pattern-break stall at 360 ns/word and at the ideal rate.
    word_clk = 18; hps_lat = 4600; hps_hit_lat = 200;
    run_break(32'h40000, 32'h80000, 32'h80400);
    word_clk = 1;  hps_lat = 4600; hps_hit_lat = 200;
    run_break(32'h50000, 32'h90000, 32'h90400);

    done = 1'b1;
  end

endmodule
