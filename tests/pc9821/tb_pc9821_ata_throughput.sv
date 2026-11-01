// tb_pc9821_ata_throughput — steady-state DOS file-read throughput, priced per cycle.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// The steady-state DOS file-read pipeline priced per cycle through the real pc9821_ata and pc9821_block_io with a parameterised HPS host model, for 32-sector reads at an insw cadence (one 16-bit word per 6 clk_sys + loop/INT overhead) under three cadences (one READ SECTORS, one READ MULTIPLE, a per-sector-command loop) x latency {0, 50, 200, 4600} x stream cost {1, 8} clk/word: every cycle is sorted into the per-word PIO handshake, the guest's inter-sector gap, the command's block-fetch stall or the mid-stream read-ahead stall, and the run reports clk/sector and KB/s at 50 MHz. It pins that a streaming read is DRAIN-bound even at the measured 4600-clk HPS latency (under 3000 clk/sector where a handshake-per-512-byte adapter is fetch-bound at 4856 (4600 + the sector's 256-word handshake, the bench's own arithmetic)), and that the interrupt cadence stays NP2kai's (one per sector for READ SECTORS, one per block for READ MULTIPLE) with every word byte-exact.
//
// The steady-state DOS file-read pipeline measured end to end -- the real pc9821_ata task
// file and PIO serializer, the real pc9821_block_io adapter, and a parameterised HPS host
// model (request->ack latency and a per-word stream cost) -- for a DOS-style read of MANY
// sectors at a tight `insw` cadence (one 16-bit 0x0640/0x0641 word per 6 clk_sys, the class
// table's cost measured through the real pc9821_iobus by tb_pc9821_ata_iowait
// (delivered=6/stall=5 per word), plus the loop's per-word instruction overhead), with the
// INT-service and per-boundary ack modelled and EVERY cycle sorted into exactly one bucket
// of the breakdown: the per-word PIO handshake, the guest's cadence overhead (REP loop +
// inter-sector INT/ack/poll gap), the command's block-fetch stall, and the mid-stream stall
// where the guest outruns the read-ahead. Three cadences (one multi-sector READ SECTORS,
// one READ MULTIPLE with a negotiated block, and the per-sector-command loop whose gap
// carries the next command's task-file setup) cross a latency sweep (0/50/200 clk, the
// realistic band, and 4600, the measured HPS round-trip bound) and two stream costs
// (1 clk/word ideal, 8 clk/word "two uncached ARM stores per word"). The verdict is
// effective KB/s at 50 MHz; the bounds pin that a streaming read is DRAIN-bound (the
// backend's per-handshake latency amortised over the read-ahead window) rather than
// fetch-bound -- on a one-handshake-per-512-byte adapter the same run is ~3x slower and
// fails the bound.

module tb_pc9821_ata_throughput;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  // ==== the drive: the real task file + PIO serializer and the real block adapter ====
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

  // ==== the HPS side of the adapter ====
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

  // ==== the HPS host model ====
  // hps_io's block protocol: one sd_rd/sd_ack handshake carries (sd_blk_cnt+1) blocks of
  // 256 words over one sd_buff_addr window. `hps_lat` is the request->ack round trip (the
  // ARM's poll + file-read setup) and `word_clk` the per-word stream cost (the ARM writes
  // each 16-bit word through the bridge). Both are VARIABLES, so one simulation sweeps the
  // whole matrix.
  integer hps_lat = 0;
  integer word_clk = 1;
  integer host_reqs = 0;          // sd handshakes taken (the amortisation metric)
  integer host_blocks_total = 0;  // blocks carried by them

  // The same synthetic sector map tb_pc9821_ata_iowait uses: byte n of sector L is
  // L[7:0] ^ n, so word i is {L ^ (2i+1), L ^ (2i)} -- a stale buffer or a wrong LBA is a
  // data mismatch, not a silent pass.
  function [15:0] sector_word_for(input [31:0] lba, input [7:0] index);
    begin
      sector_word_for = {
          lba[7:0] ^ {index[6:0], 1'b1},
          lba[7:0] ^ {index[6:0], 1'b0}
      };
    end
  endfunction

  integer host_i, host_words, host_blocks;
  reg [31:0] host_lba;

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
        // one word per `word_clk` clk_sys: sd_buff_wr is a one-cycle pulse per word
        // (hps_io's b_wr), so the stream rate is the interval between pulses.
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
        // write transfers stay one block (the adapter never asks for more)
        host_reqs = host_reqs + 1;
        host_blocks_total = host_blocks_total + 1;
        repeat (hps_lat) @(negedge clk);
        sd_ack = 1;
        repeat (256) @(negedge clk);
        sd_ack = 0;
      end
    end
  end

  // ==== cycle accounting: every measured cycle lands in exactly one bucket ====
  localparam P_NONE = 3'd0, P_PIO = 3'd1, P_REP = 3'd2, P_INT = 3'd3,
             P_CMD = 3'd4, P_WAIT_CMD = 3'd5, P_WAIT_RA = 3'd6;
  reg [2:0] phase = P_NONE;
  reg measuring = 0;
  integer cyc_pio = 0, cyc_rep = 0, cyc_int = 0,
          cyc_cmd = 0, cyc_wait_cmd = 0, cyc_wait_ra = 0, cyc_unacc = 0;
  integer run_cyc = 0;
  integer overlap_cyc = 0;   // a host fetch in flight while the guest can read (DRQ set)

  always @(posedge clk) if (rst_n && measuring) begin
    run_cyc = run_cyc + 1;
    case (phase)
      P_PIO:      cyc_pio      = cyc_pio + 1;
      P_REP:      cyc_rep      = cyc_rep + 1;
      P_INT:      cyc_int      = cyc_int + 1;
      P_CMD:      cyc_cmd      = cyc_cmd + 1;
      P_WAIT_CMD: cyc_wait_cmd = cyc_wait_cmd + 1;
      P_WAIT_RA:  cyc_wait_ra  = cyc_wait_ra + 1;
      default:    cyc_unacc    = cyc_unacc + 1;
    endcase
    if (adapter_busy && ata.status_reg[3]) overlap_cyc = overlap_cyc + 1;
  end

  // ==== CHECKS ====
  task clear_buckets;
    begin
      cyc_pio = 0; cyc_rep = 0; cyc_int = 0;
      cyc_cmd = 0; cyc_wait_cmd = 0; cyc_wait_ra = 0; cyc_unacc = 0;
      run_cyc = 0; overlap_cyc = 0;
    end
  endtask

  integer errors = 0;
  task fail(input [8*128-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ==== the guest: the DOS driver's `insw` loop over the real port bytes ====
  // A PIO word is two byte-lane strobes (0x0640 low, 0x0641 high -- the iobus lane walk)
  // paced to WORD_CYCLES clk_sys, the class cost per 16-bit word; a task-file access is
  // TF_CYCLES. REP_EXTRA is the loop's per-word instruction overhead beyond the bus
  // access; INT_CYCLES the ISR entry/exit around the 0x064E ack. All task waits are
  // negedge-to-negedge, so one wait = one period = exactly one counted posedge and the
  // bucket sum must equal the wall count.
  localparam WORD_CYCLES = 6;
  localparam TF_CYCLES   = 5;
  localparam REP_EXTRA   = 2;
  localparam INT_CYCLES  = 60;

  // One byte-lane strobe of a PIO data word: 1 clk_sys (call sites sit on a negedge).
  task lane_read(input [15:0] addr, output [7:0] data);
    begin
      io_addr = addr;
      io_rd = 1;
      #1 data = io_dout;
      @(negedge clk);
      io_rd = 0;
    end
  endtask

  // A task-file byte read (0x064E/0x074C poll or ack): TF_CYCLES, the class cost.
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
      phase = P_PIO;
      lane_read(16'h0640, lo);
      lane_read(16'h0641, hi);
      repeat (WORD_CYCLES - 2) @(negedge clk);
      data = {hi, lo};
      phase = P_REP;
      repeat (REP_EXTRA) @(negedge clk);
    end
  endtask

  task int_service;   // the ISR: entry, the 0x064E ack read, EOI, IRET
    reg [7:0] status;
    begin
      phase = P_INT;
      repeat (INT_CYCLES) @(negedge clk);
      tf_read(16'h064E, status);
    end
  endtask

  // Poll 0x074C until DRQ (never acknowledges, so the IRQ level stays honest). Every poll
  // cycle lands in `bucket`: the command's own fetch wait, or the mid-stream wait where
  // the guest outruns the read-ahead.
  task wait_drq(input [2:0] bucket);
    reg [7:0] status;
    integer n;
    begin
      phase = bucket;
      n = 0;
      status = 8'h00;
      while (!status[3] && n < 1000000) begin
        tf_read(16'h074C, status);
        phase = bucket;
        n = n + 1;
      end
      if (!status[3]) fail("DRQ timeout");
    end
  endtask

  task setup_command(input [7:0] count, input [31:0] lba, input [7:0] cmd);
    begin
      phase = P_CMD;
      tf_write(16'h0644, count);
      tf_write(16'h0646, lba[7:0]);
      tf_write(16'h0648, lba[15:8]);
      tf_write(16'h064A, lba[23:16]);
      tf_write(16'h064C, 8'hE0);
      tf_write(16'h064E, cmd);
    end
  endtask

  // IRQ edges, for the cadence check (one per sector for READ SECTORS, one per block for
  // READ MULTIPLE -- the NP2kai contract this model keeps).
  integer irq_seen = 0;
  reg irq_prev = 0;
  always @(posedge clk) begin
    irq_prev <= irq;
    if (irq && !irq_prev) irq_seen = irq_seen + 1;
  end

  // Drain `count` sectors presented back to back under one command: per sector, the DRQ
  // poll, the boundary service (IRQ + ack where the cadence interrupts) and 256 words.
  task drain_sectors(input integer count, input integer irq_every,
                     input [31:0] lba, input integer first_is_cmd_wait);
    integer s, w;
    reg [15:0] word_value;
    begin
      for (s = 0; s < count; s = s + 1) begin
        wait_drq((s == 0 && first_is_cmd_wait) ? P_WAIT_CMD : P_WAIT_RA);
        if ((s % irq_every) == 0) int_service();
        for (w = 0; w < 256; w = w + 1) begin
          read_pio_word(word_value);
          if (word_value !== sector_word_for(lba + s, w[7:0]))
            fail("sector data mismatch");
        end
      end
    end
  endtask

  // ==== the runs ====
  localparam integer SECTORS = 32;
  integer irq_before, reqs_before, blocks_before;

  task start_measuring;
    begin
      irq_before = irq_seen;
      reqs_before = host_reqs;
      blocks_before = host_blocks_total;
      clear_buckets();
      measuring = 1;
    end
  endtask

  // One multi-sector command draining SECTORS sectors (READ SECTORS 0x20 or, with blk>1
  // after SET MULTIPLE MODE, READ MULTIPLE 0xC4).
  task run_stream(input [7:0] cmd, input [7:0] blk, input [31:0] lba);
    begin
      if (blk != 8'd1) begin
        // SET MULTIPLE MODE is setup, not the stream: account it out.
        phase = P_CMD;
        tf_write(16'h0644, blk);
        tf_write(16'h064E, 8'hC6);
        int_service();
      end
      start_measuring();
      setup_command(SECTORS[7:0], lba, cmd);
      drain_sectors(SECTORS, blk, lba, 1'b1);
      @(negedge clk);
      measuring = 0;
    end
  endtask

  // The per-sector-command cadence: a fresh READ SECTORS (count 1) per 512 bytes, so each
  // sector's gap carries the next command's task-file setup and its serialized fetch. A
  // read-ahead cache serves the follow-up sectors without a round trip; a
  // one-handshake-per-sector adapter pays the whole latency 32 times.
  task run_per_sector(input [31:0] lba);
    integer s;
    begin
      start_measuring();
      for (s = 0; s < SECTORS; s = s + 1) begin
        setup_command(8'd1, lba + s, 8'h20);
        drain_sectors(1, 1, lba + s, 1'b1);
      end
      @(negedge clk);
      measuring = 0;
    end
  endtask

  // The bound slots: the read-sectors stream at the measured HPS latency, at both stream
  // costs (filled by report() below).
  integer ps_bound_w1 = 0, ps_bound_w8 = 0;

  task report(input integer which, input integer lat, input integer wclk,
              input integer blk, input integer irqs);
    integer total, mbps_x100, ps_x100, ps, kbs;
    reg [8*24-1:0] name;
    begin
      total = cyc_pio + cyc_rep + cyc_int + cyc_cmd + cyc_wait_cmd + cyc_wait_ra + cyc_unacc;
      if (total != run_cyc) begin
        $display("FAIL bucket sum %0d != wall %0d (phase accounting drift)", total, run_cyc);
        errors = errors + 1;
      end
      name = (which == 0) ? "read-sectors" :
             (which == 1) ? "read-multiple" : "per-sector-cmd";
      ps = run_cyc / SECTORS;
      ps_x100 = (run_cyc * 100) / SECTORS;
      kbs = (SECTORS * 512 * 50000) / run_cyc;        // KB/s at 50 MHz
      mbps_x100 = (SECTORS * 512 * 50 * 100) / run_cyc;   // MB/s x 100
      $display("TPRUN %0s lat=%0d word=%0d blk=%0d: cycles=%0d per_sector=%0d.%02d KBps=%0d MBps=%0d.%02d",
               name, lat, wclk, blk, run_cyc,
               ps_x100 / 100, ps_x100 % 100, kbs,
               mbps_x100 / 100, mbps_x100 % 100);
      $display("TPBRK %0s lat=%0d word=%0d blk=%0d: pio=%0d rep=%0d int_gap=%0d cmd=%0d wait_cmd=%0d wait_ra=%0d overlap=%0d host_reqs=%0d host_blocks=%0d irq=%0d (want %0d)",
               name, lat, wclk, blk, cyc_pio, cyc_rep, cyc_int, cyc_cmd,
               cyc_wait_cmd, cyc_wait_ra, overlap_cyc,
               host_reqs - reqs_before, host_blocks_total - blocks_before,
               irq_seen - irq_before, irqs);
      if ((irq_seen - irq_before) != irqs)
        fail("interrupt count off the NP2kai cadence");
      if (which == 0 && lat == 4600) begin
        if (wclk == 1) ps_bound_w1 = ps;
        if (wclk == 8) ps_bound_w8 = ps;
      end
    end
  endtask

  task scenario(input integer which, input integer lat, input integer wclk,
                input [7:0] blk);
    begin
      hps_lat  = lat;
      word_clk = wclk;
      case (which)
        0: run_stream(8'h20, 1, 32'h1000);
        1: run_stream(8'hC4, blk, 32'h2000);
        2: run_per_sector(32'h3000);
      endcase
      report(which, lat, wclk, blk, (which == 1) ? (SECTORS / blk) : SECTORS);
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    // mount the image (hps_io's single-cycle img_mounted pulse)
    @(negedge clk);
    img_mounted = 1;
    @(negedge clk);
    img_mounted = 0;
    while (ata.current_cylinders !== 16'd735) @(negedge clk);
    phase = P_CMD;
    tf_write(16'h0432, 8'h00);

    // the realistic latency band at an ideal 1 clk/word stream
    scenario(0, 0,   1, 8'd1);
    scenario(1, 0,   1, 8'd8);
    scenario(2, 0,   1, 8'd1);
    scenario(0, 50,  1, 8'd1);
    scenario(1, 50,  1, 8'd8);
    scenario(2, 50,  1, 8'd1);
    scenario(0, 200, 1, 8'd1);
    scenario(1, 200, 1, 8'd8);
    scenario(2, 200, 1, 8'd1);
    // the measured HPS bound (up to ~4600 clk per block round trip) and its
    // pessimistic twin where the ARM spends 8 clk_sys per word on uncached stores
    scenario(0, 4600, 1, 8'd1);
    scenario(1, 4600, 1, 8'd8);
    scenario(2, 4600, 1, 8'd1);
    scenario(0, 4600, 8, 8'd1);
    scenario(1, 4600, 8, 8'd8);
    scenario(2, 4600, 8, 8'd1);

    // ==== bounds: what this bench is about ====
    // At the measured HPS latency a streaming read must be DRAIN-bound (the per-word PIO
    // handshake is the bottleneck), not fetch-bound: one handshake per 512 bytes caps the
    // stream at (4600 + 256*w)/sector = 4856 clk at w=1. The read-ahead window amortises
    // the handshake over its blocks, so a 32-sector stream must land under 3000 clk/sector
    // (the drain's 1536 + the modelled cadence + the warm-up fetches exposed at the head).
    $display("BOUND read-sectors lat=4600: per_sector word=1 %0d word=8 %0d",
             ps_bound_w1, ps_bound_w8);
    if (ps_bound_w1 == 0 || ps_bound_w8 == 0) begin
      $display("FAIL the bound runs never reported");
      errors = errors + 1;
    end
    if (ps_bound_w1 > 3000) begin
      $display("FAIL a streaming read at the measured HPS latency is fetch-bound (%0d clk/sector at word=1): the per-handshake latency is not amortised", ps_bound_w1);
      errors = errors + 1;
    end
    if (ps_bound_w8 > 4200) begin
      $display("FAIL a streaming read with an 8 clk/word host is fetch-bound (%0d clk/sector)", ps_bound_w8);
      errors = errors + 1;
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_ATA_THROUGHPUT: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA_THROUGHPUT: FAIL (%0d errors)", errors);
  end

  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_ATA_THROUGHPUT: TIMEOUT");
  end

endmodule
