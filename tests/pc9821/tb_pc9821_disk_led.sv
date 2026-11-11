// tb_pc9821_disk_led - the access lamps light on data transfers, never on polls.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DISK_LED: The access lamp (pc9821_disk_led's led_disk, MiSTer LED_DISK, the lamp the I/O board shows) lights on the drives' DATA TRANSFERS with their images and on nothing else, as ao486 drives its lamps from the HPS block requests alone (ao486.sv `led hdd_led(clk_sys, |mgmt_req[5:0], LED_DISK[0]);`): with the REAL pc9821_ata (a mounted disk behind a block-engine model), the REAL pc9821_atapi (a mounted ISO behind an hps_io slot model) and the REAL pc9821_fdc (unit 0 with media, a DMA model), both lamps stay dark through a status-poll storm, IDENTIFY DEVICE and CHECK POWER MODE on the disk, TEST UNIT READY, GET EVENT STATUS NOTIFICATION, INQUIRY and REQUEST SENSE (the last two with a data phase) on the CD drive and SENSE DRIVE STATUS and SENSE INTERRUPT STATUS on the floppy controller; led_disk is lit in every cycle a two-sector READ SECTORS has a block request out at the engine, a CD READ(10) has its sector request out at the host, and a floppy READ DATA runs from its last parameter byte to its result interrupt, and goes out 50 ms of clk after the last of these ends (a second READ SECTORS inside the hold restarts it); the floppy lamp (led_fdd, MiSTer LED_USER) lights for the floppy READ DATA alone, with the same hold.
//
// The expected behaviour is observed from the HOST's side, never from the RTL's own state: a
// transfer is in progress from the cycle the bench's block engine / hps_io model sees the request
// to the cycle it answers the last word (block_done; sd_ack dropped), and for the floppy from the
// command's last parameter byte to the result interrupt. The hold is the design constant HOLD_MS
// = 50 at the bench's CLK_HZ = 100 kHz: 5000 clk.
//
// FAIL-FIRST: before this change the lamp followed BSY|DRQ (ATA DASP-) and the FDC's MSR CB, so
// every polling command lit it and the floppy lamp was on LED_USER only; this bench, run against
// that tree with its ports adapted (led_ide for led_disk, `active` for `xfer`, the FDC's st beside
// x_st), fails at the poll checks and at the floppy READ DATA's led_disk check. The mutations in
// tests/pc9821/mutations.json each fail it.

module tb_pc9821_disk_led;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  integer errors = 0;

  localparam integer CLK_HZ = 100_000;
  localparam integer HOLD   = (CLK_HZ / 1000) * 50;   // 50 ms of clk

  // cyc counts clk edges; every timing below is in these units.
  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ==== the IDE bus: the real disk and the real CD drive, pc9821_system's read mux ====
  reg io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] ata_dout, cd_dout;
  wire cd_own, cd_irq, ata_irq;
  wire [7:0] dout = cd_own ? cd_dout : ata_dout;
  wire ata_xfer, cd_xfer;

  wire        block_read, block_write;
  wire [31:0] block_lba;
  reg         block_done = 0, block_buf_we = 0;
  reg  [ 7:0] block_buf_addr = 0;
  reg  [15:0] block_buf_data = 0;

  reg         img_mounted = 0;
  reg  [63:0] img_size = 0;
  wire [31:0] sd_lba;
  wire [5:0]  sd_blk_cnt;
  wire        sd_rd;
  reg         sd_ack = 0, sd_buff_wr = 0;
  reg  [12:0] sd_buff_addr = 0;
  reg  [15:0] sd_buff_dout = 0;

  // ==== DUT ====
  /* verilator lint_off PINCONNECTEMPTY */
  pc9821_ata ata (
      .clk(clk), .rst_n(rst_n),
      .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din), .io_dout(ata_dout),
      .mounted(1'b1), .readonly(1'b0), .capacity(32'd1000),
      .mounted1(1'b0), .readonly1(1'b0), .capacity1(32'd0),
      .block_read(block_read), .block_write(block_write), .block_lba(block_lba),
      .block_unit(),
      .block_done(block_done), .block_error(1'b0), .block_buf_we(block_buf_we),
      .block_buf_addr(block_buf_addr), .block_buf_data(block_buf_data),
      .block_rd_addr(8'd0), .block_rd_data(),
      .irq(ata_irq), .xfer(ata_xfer),
      .dbg_state(), .dbg_cmd(), .dbg_lba(), .dbg_sec()
  );

  pc9821_atapi #(.AUDIO_EN(1'b0), .LOG_EN(1'b0)) cd (
      .clk(clk), .rst_n(rst_n),
      .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din), .io_dout(cd_dout),
      .io_own(cd_own), .irq(cd_irq), .xfer(cd_xfer),
      .img_mounted(img_mounted), .img_size(img_size),
      .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_ack(sd_ack),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
      .cdda_req(1'b0), .cdda_req4(1'b0), .cdda_played(1'b0),
      .cdda_flush(), .cdda_wr(), .cdda_data(),
      .log_byte(), .log_we(), .log_accept(1'b1)
  );

  // ==== the floppy controller: unit 0 has a medium, DMA mode (the reset default) ====
  reg       f_cs = 0, f_wr = 0, f_rd = 0;
  reg [1:0] f_addr = 0;
  reg [7:0] f_din = 0;
  wire [7:0] f_dout;
  wire       f_irq;
  wire [7:0] fdc_dbg_state;
  wire       media_req, media_adv, dma_drq;
  wire [7:0] media_idx, media_r, dma_dout;
  reg        dma_dack = 0, dma_stb = 0, dma_tc = 0;
  reg        m_xfer = 0;
  reg [15:0] m_ptr = 0;
  pc9821_fdc fdc (
      .clk(clk), .reset(!rst_n), .cs(f_cs), .addr({1'b0, f_addr}),
      .wr(f_wr), .rd(f_rd), .din(f_din), .dout(f_dout), .irq(f_irq), .res_done(),
      .win_2dd(1'b0), .strap_2hd(),
      .media_present(4'b0001), .writeprotect(4'b0001), .media_chg(4'd0), .frame_tick(1'b0),
      .media_req(media_req), .media_req_hdr(), .media_unit(),
      .media_c(), .media_h(), .media_tc(), .media_hd(), .media_mf(), .media_2hd(), .media_rpm(),
      .media_r(media_r), .media_n(), .media_idx(media_idx), .media_wr(), .media_din(),
      .media_abort(),
      .media_ready(!m_xfer), .media_rdy(m_xfer), .media_hdrv(1'b0), .media_err(1'b0),
      .media_dout(m_ptr[7:0]), .media_hr(media_idx + 8'd1), .media_hn(8'd3), .media_hs(8'd8),
      .media_adv(media_adv), .dma_drq(dma_drq), .dma_dack(dma_dack), .dma_stb(dma_stb),
      .dma_tc(dma_tc), .dma_dout(dma_dout), .dma_we(1'b0), .dma_din(8'h00),
      .dbg_state(fdc_dbg_state), .dbg_cmd(), .dbg_result(), .dbg_chrn()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // ==== the lamps, wired as pc9821_system wires them ====
  wire led_disk, led_fdd;
  pc9821_disk_led #(.CLK_HZ(CLK_HZ), .HOLD_MS(50)) dut (
      .clk(clk), .reset(!rst_n),
      .ata_xfer(ata_xfer), .cd_xfer(cd_xfer),
      .fdc_x_st(fdc_dbg_state[2:0]),
      .led_disk(led_disk), .led_fdd(led_fdd)
  );

  task automatic fail(input string msg);
    begin
      errors = errors + 1;
      $display("FAIL: %s @ %0t", msg, $time);
    end
  endtask

  // ==== the block engine: 400 clk of latency, then 256 words, then one done ====
  // b_active is the HOST's view of a sector transfer: from the request it sees to its done.
  reg     b_active = 0;
  integer b_wait = 0, b_index = 0, b_done_cyc = 0;
  always @(negedge clk) begin
    block_done   = 0;
    block_buf_we = 0;
    if (!b_active && (block_read || block_write)) begin
      b_active = 1; b_wait = 400; b_index = 0;
    end else if (b_active && b_wait > 0) b_wait = b_wait - 1;
    else if (b_active) begin
      block_buf_we   = 1;
      block_buf_addr = b_index[7:0];
      block_buf_data = {b_index[7:0], block_lba[7:0]};
      if (b_index == 255) begin b_active = 0; block_done = 1; b_done_cyc = cyc; end
      else b_index = b_index + 1;
    end
  end

  // ==== hps_io's side of the CD slot: one request at a time, the image's words ====
  localparam integer ISO_SECS = 16;
  function automatic [7:0] dbyte(input integer l, input integer i);
    dbyte = 8'((i ^ (i >> 8) * 29) + l * 13 + 1);
  endfunction
  byte    img [];
  reg     h_active = 0;      // the host is serving a request (request seen .. ack dropped)
  integer h_sec_reqs = 0, h_end_cyc = 0;
  always @(negedge clk) begin : host
    reg [31:0] lba; integer words;
    if (sd_rd && !sd_ack) begin
      lba = sd_lba; words = (sd_blk_cnt + 1) * 256;
      h_active = (lba != 0);  // LBA 0 is the mount's header fetch, not a guest read
      if (lba != 0) h_sec_reqs = h_sec_reqs + 1;
      repeat (6) @(negedge clk);
      sd_ack = 1;
      repeat (3) @(negedge clk);
      for (int w = 0; w < words; w++) begin
        longint o; o = longint'(lba) * 512 + w * 2;
        sd_buff_addr = 13'(w);
        sd_buff_dout = {(o + 1 < img.size()) ? img[o + 1] : 8'h00, (o < img.size()) ? img[o] : 8'h00};
        sd_buff_wr = 1; @(negedge clk); sd_buff_wr = 0; @(negedge clk);
      end
      repeat (2) @(negedge clk);
      sd_ack = 0;
      if (h_active) h_end_cyc = cyc;
      h_active = 0;
    end
  end

  // ==== the floppy medium (pc9821_fdd_media's seam) and the DMA engine (pc9821_dmac's) ====
  // The medium answers a data request with a 1024-byte sector (N = 3) on the next clock; `adv`
  // consumes a byte. The DMA engine strobes one byte per DRQ, TC with the final strobe.
  always @(posedge clk) begin
    if (!rst_n) begin m_xfer <= 1'b0; m_ptr <= 16'd0; end
    else begin
      if (media_req) begin m_xfer <= 1'b1; m_ptr <= 16'd0; end
      if (m_xfer && media_adv) begin
        if (m_ptr == 16'd1023) m_xfer <= 1'b0;
        m_ptr <= m_ptr + 16'd1;
      end
    end
  end
  reg [15:0] dm_left = 0;
  reg        dm_armed = 0;
  integer    dm_n = 0;
  always @(posedge clk) begin
    dma_dack <= 1'b0; dma_stb <= 1'b0; dma_tc <= 1'b0;
    if (dm_armed) begin
      dm_n <= dm_n + 1; dm_left <= dm_left - 16'd1; dm_armed <= 1'b0;
    end else if (dma_drq && dm_left != 16'd0) begin
      dma_dack <= 1'b1; dma_stb <= 1'b1; dma_tc <= (dm_left == 16'd1); dm_armed <= 1'b1;
    end
  end

  // ==== the lamp monitor ====
  // dark: every lamp sample must be 0. disk_want / fdd_want: the lamp must be lit while the
  // host-side transfer marks above say a transfer is under way (two clk of slack from its start:
  // the drive's own state register, then the lamp's).
  reg     dark = 0, f_busy = 0;
  integer dark_disk_lit = 0, dark_fdd_lit = 0, disk_gaps = 0, fdd_gaps = 0;
  integer f_from = 0;
  reg     b_q1 = 0, b_q2 = 0, h_q1 = 0, h_q2 = 0;
  always @(posedge clk) begin
    b_q1 <= b_active; b_q2 <= b_q1 && b_active;
    h_q1 <= h_active; h_q2 <= h_q1 && h_active;
    if (dark && led_disk !== 1'b0) dark_disk_lit <= dark_disk_lit + 1;
    if (dark && led_fdd  !== 1'b0) dark_fdd_lit  <= dark_fdd_lit + 1;
    if ((b_q2 && b_active) || (h_q2 && h_active) || (f_busy && cyc >= f_from))
      if (led_disk !== 1'b1) disk_gaps <= disk_gaps + 1;
    if (f_busy && cyc >= f_from && led_fdd !== 1'b1) fdd_gaps <= fdd_gaps + 1;
  end

  // ==== host accesses (pc9821_iobus's one-cycle strobes) ====
  task automatic wr(input [15:0] a, input [7:0] d);
    begin
      @(negedge clk); io_addr = a; io_din = d; io_wr = 1;
      @(negedge clk); io_wr = 0;
    end
  endtask
  task automatic rd(input [15:0] a, output [7:0] d);
    begin
      @(negedge clk); io_addr = a; io_rd = 1; #1 d = dout;
      @(negedge clk); io_rd = 0;
    end
  endtask
  task automatic fwr(input [1:0] a, input [7:0] d);
    begin
      @(negedge clk); f_cs = 1; f_addr = a; f_wr = 1; f_din = d;
      @(negedge clk); f_cs = 0; f_wr = 0;
    end
  endtask
  task automatic frd(input [1:0] a, output [7:0] d);
    begin
      @(negedge clk); f_cs = 1; f_addr = a; f_rd = 1; #1 d = f_dout;
      @(negedge clk); f_cs = 0; f_rd = 0;
    end
  endtask

  // The transfer has ended at `t_end` (the host's last answer): the lamp must go out between lo
  // and hi clk after t_end, and stay out for a while.
  task automatic expect_hold(input bit is_fdd, input integer t_end, input integer lo,
                             input integer hi, input string what);
    integer off_at;
    begin
      off_at = -1;
      while (cyc < t_end + hi + 50 && off_at < 0) begin
        @(posedge clk); #1;
        if ((is_fdd ? led_fdd : led_disk) !== 1'b1) off_at = cyc;
      end
      if (off_at < 0) fail({what, ": the lamp never went out after the transfer ended"});
      else if (off_at - t_end < lo || off_at - t_end > hi) begin
        errors = errors + 1;
        $display("FAIL: %s: the lamp went out %0d clk after the transfer ended, want %0d..%0d (the 50 ms hold)",
                 what, off_at - t_end, lo, hi);
      end
      repeat (200) begin
        @(posedge clk); #1;
        if ((is_fdd ? led_fdd : led_disk) !== 1'b0) begin
          fail({what, ": the lamp came back on with no transfer"}); break;
        end
      end
    end
  endtask

  // ---- the hard disk (bank 0) ----
  task automatic ata_wait_ready(input string what);
    reg [7:0] s; integer k;
    begin
      k = 0;
      do begin rd(16'h074C, s); k = k + 1; end while (s[7] && k < 5000);
      if (s[7]) $fatal(1, "TB_PC9821_DISK_LED: FAIL - %s: BSY never cleared", what);
    end
  endtask
  // A command answered from the drive's own state with a 256-word data phase (IDENTIFY).
  task automatic ata_pio_in(input [7:0] c, input string what);
    reg [7:0] s, lo, hi;
    begin
      wr(16'h064E, c);
      ata_wait_ready(what);
      rd(16'h074C, s);
      if (!s[3]) begin errors++; $display("FAIL: %s: no data phase (status %02x)", what, s); end
      for (int w = 0; w < 256; w++) begin rd(16'h0640, lo); rd(16'h0641, hi); end
      rd(16'h064E, s);
      if (s !== 8'h50) begin errors++; $display("FAIL: %s: ended with status %02x, want 50", what, s); end
    end
  endtask
  // READ SECTORS (0x20), polled on the alternate status, every data word read.
  task automatic read_sectors(input [7:0] lba, input integer n);
    reg [7:0] s, lo, hi; integer k;
    begin
      wr(16'h0644, 8'(n)); wr(16'h0646, lba); wr(16'h0648, 8'h00); wr(16'h064A, 8'h00);
      wr(16'h064C, 8'hE0);
      wr(16'h064E, 8'h20);
      for (int sec = 0; sec < n; sec++) begin
        k = 0;
        do begin rd(16'h074C, s); k = k + 1; end while ((s[7] || !s[3]) && k < 5000);
        if (!s[3]) $fatal(1, "TB_PC9821_DISK_LED: FAIL - READ SECTORS never reached DRQ");
        for (int w = 0; w < 256; w++) begin rd(16'h0640, lo); rd(16'h0641, hi); end
      end
      rd(16'h074C, s);
      if (s !== 8'h50) begin errors++; $display("FAIL: READ SECTORS ended with status %02x, want 50", s); end
    end
  endtask

  // ---- the CD drive (bank 1): a packet command, polled, every data phase read ----
  integer rlen;
  reg [7:0] pk_status;
  task automatic packet(input byte c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, input string what);
    reg [7:0] s, bl, bh, lo, hi; integer cnt, phases, k;
    byte cdb [0:11];
    begin
      cdb = '{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, 8'h00, 8'h00};
      rlen = 0;
      wr(16'h064E, 8'hA0);
      k = 0;
      do begin rd(16'h074C, s); k = k + 1; end while (!s[3] && k < 5000);
      if (!s[3]) $fatal(1, "TB_PC9821_DISK_LED: FAIL - %s: no packet phase", what);
      for (int i = 0; i < 6; i++) begin wr(16'h0640, cdb[2 * i]); wr(16'h0641, cdb[2 * i + 1]); end
      phases = 0;
      forever begin
        k = 0;
        do begin rd(16'h074C, s); k = k + 1; end while (s[7] && k < 200000);
        if (s[7]) $fatal(1, "TB_PC9821_DISK_LED: FAIL - %s: BSY never cleared", what);
        if (!s[3]) break;
        rd(16'h0648, bl); rd(16'h064A, bh);
        cnt = {bh, bl};
        for (int w = 0; w < (cnt + 1) / 2; w++) begin rd(16'h0640, lo); rd(16'h0641, hi); end
        rlen = rlen + cnt;
        phases++;
        if (phases > 64) $fatal(1, "TB_PC9821_DISK_LED: FAIL - %s: runaway data phases", what);
      end
      rd(16'h064E, pk_status);
    end
  endtask

  // ---- the floppy controller ----
  // A command with a result phase and no data: the command byte, its parameters, every result
  // byte, then the MSR back at idle.
  task automatic fdc_sense(input [7:0] c, input integer nparam, input string what);
    reg [7:0] m, r; integer k;
    begin
      fwr(2'd1, c);
      for (int i = 0; i < nparam; i++) fwr(2'd1, 8'h00);
      k = 0;
      do begin frd(2'd0, m); k = k + 1; end while (m[7:6] != 2'b11 && k < 5000);
      if (m[7:6] != 2'b11) $fatal(1, "TB_PC9821_DISK_LED: FAIL - %s: no result phase (MSR %02x)", what, m);
      while (m[7:6] == 2'b11 && k < 10000) begin frd(2'd1, r); frd(2'd0, m); k = k + 1; end
      if (m !== 8'h80) begin errors++; $display("FAIL: %s: MSR after the result %02x, want 80", what, m); end
    end
  endtask
  // READ DATA (0x46 = MF, unit 0) of C0 H0 R1 N3 EOT8, ended by the DMA engine's TC after one
  // 1024-byte sector. Returns the cycle the result interrupt rose.
  task automatic fdc_read_data(output integer t_end);
    reg [7:0] m, r; integer k;
    begin
      dm_left = 16'd1024; dm_n = 0;
      fwr(2'd1, 8'h46);
      fwr(2'd1, 8'h00); fwr(2'd1, 8'h00); fwr(2'd1, 8'h00); fwr(2'd1, 8'h01);
      fwr(2'd1, 8'h03); fwr(2'd1, 8'h08); fwr(2'd1, 8'h1B);
      fwr(2'd1, 8'hFF);                 // the last parameter: the command executes
      f_from = cyc + 3; f_busy = 1;
      k = 0;
      while (!f_irq && k < 2_000_000) begin @(posedge clk); #1; k = k + 1; end
      t_end = cyc;
      f_busy = 0;
      if (!f_irq) $fatal(1, "TB_PC9821_DISK_LED: FAIL - READ DATA never interrupted");
      if (dm_n != 1024) begin errors++; $display("FAIL: READ DATA moved %0d bytes by DMA, want 1024", dm_n); end
      k = 0;
      do begin frd(2'd0, m); k = k + 1; end while (m[7:6] != 2'b11 && k < 5000);
      for (int i = 0; i < 7; i++) begin
        frd(2'd1, r);
        if (i == 0 && r[7:6] !== 2'b00) begin errors++; $display("FAIL: READ DATA ST0 %02x, want normal termination", r); end
      end
      frd(2'd0, m);
      if (m !== 8'h80) begin errors++; $display("FAIL: the FDC's MSR after READ DATA is %02x, want 80", m); end
    end
  endtask

  // ==== CHECKS ====
  reg [7:0] s;
  integer t1;
  initial begin
    img = new[ISO_SECS * 2048];
    for (int l = 0; l < ISO_SECS; l++)
      for (int i = 0; i < 2048; i++) img[l * 2048 + i] = dbyte(l, i);
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (50) @(negedge clk);
    // the CD's mount: one hps_io img_mounted pulse, then its header fetch
    img_size = img.size();
    @(negedge clk); img_mounted = 1; @(negedge clk); img_mounted = 0;
    repeat (20000) @(negedge clk);
    repeat (HOLD + 100) @(negedge clk);

    // ---- 1. polling every drive: both lamps dark throughout ----
    dark = 1;
    wr(16'h0432, 8'h00);                             // bank 0: the hard disk
    for (int i = 0; i < 1000; i++) rd(16'h074C, s);  // a status-poll storm
    rd(16'h064E, s);
    if (s !== 8'h50) begin errors++; $display("FAIL: the disk is not ready (%02x)", s); end
    ata_pio_in(8'hEC, "IDENTIFY DEVICE");
    wr(16'h064E, 8'hE5);                              // CHECK POWER MODE
    ata_wait_ready("CHECK POWER MODE");
    rd(16'h064E, s);
    wr(16'h0432, 8'h01); wr(16'h064C, 8'hA0);         // bank 1: the CD drive
    for (int i = 0; i < 4; i++)
      packet(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, "TEST UNIT READY");
    if (pk_status !== 8'h50) begin errors++; $display("FAIL: TEST UNIT READY status %02x, want 50", pk_status); end
    for (int i = 0; i < 4; i++)
      packet(8'h4A, 8'h01, 0, 0, 8'h10, 0, 0, 0, 8'd8, 0, "GET EVENT STATUS NOTIFICATION");
    // (this drive answers it CHECK, as NP2kai's atapicmd.c has no 0x4A arm: either way no data)
    if (pk_status !== 8'h50 && pk_status !== 8'h51) begin
      errors++; $display("FAIL: GET EVENT STATUS NOTIFICATION status %02x", pk_status);
    end
    packet(8'h12, 0, 0, 0, 8'd36, 0, 0, 0, 0, 0, "INQUIRY");
    if (rlen != 36) begin errors++; $display("FAIL: INQUIRY returned %0d bytes, want 36", rlen); end
    packet(8'h03, 0, 0, 0, 8'd18, 0, 0, 0, 0, 0, "REQUEST SENSE");
    if (rlen != 18) begin errors++; $display("FAIL: REQUEST SENSE returned %0d bytes, want 18", rlen); end
    fdc_sense(8'h04, 1, "SENSE DRIVE STATUS");
    fdc_sense(8'h08, 0, "SENSE INTERRUPT STATUS");
    repeat (300) @(negedge clk);
    dark = 0;
    if (dark_disk_lit != 0) begin
      errors++; $display("FAIL: the access lamp was lit for %0d clk while the guest only polled", dark_disk_lit);
    end
    if (dark_fdd_lit != 0) begin
      errors++; $display("FAIL: the floppy lamp was lit for %0d clk while the guest only polled", dark_fdd_lit);
    end
    if (h_sec_reqs != 0) fail("a polling command fetched a CD sector");

    // ---- 2. READ SECTORS, two sectors: lit while a block is out, out HOLD after the last ----
    wr(16'h0432, 8'h00);
    read_sectors(8'h05, 2);
    if (disk_gaps != 0) begin
      errors++; $display("FAIL: the access lamp was dark for %0d clk while a sector transfer ran", disk_gaps);
    end
    if (led_fdd !== 1'b0) fail("the floppy lamp lit for a hard-disk transfer");
    expect_hold(1'b0, b_done_cyc, HOLD - 4, HOLD + 4, "READ SECTORS");

    // ---- 3. re-trigger: a second READ SECTORS inside the hold restarts it ----
    read_sectors(8'h07, 1);
    t1 = b_done_cyc;
    repeat (HOLD / 2) @(negedge clk);
    if (led_disk !== 1'b1) fail("the access lamp is dark half-way through the hold");
    read_sectors(8'h09, 1);
    if (b_done_cyc - t1 >= HOLD) fail("the second READ SECTORS did not land inside the first's hold");
    expect_hold(1'b0, b_done_cyc, HOLD - 4, HOLD + 4, "the re-triggered hold");

    // ---- 4. CD READ(10), one sector ----
    wr(16'h0432, 8'h01); wr(16'h064C, 8'hA0);
    disk_gaps = 0;
    packet(8'h28, 0, 0, 0, 0, 8'd3, 0, 0, 8'd1, 0, "READ(10)");
    if (pk_status !== 8'h50 || rlen != 2048) begin
      errors++; $display("FAIL: READ(10) status %02x, %0d bytes, want 50 / 2048", pk_status, rlen);
    end
    if (h_sec_reqs == 0) fail("READ(10) fetched no sector from the host");
    if (disk_gaps != 0) begin
      errors++; $display("FAIL: the access lamp was dark for %0d clk while the CD sector was fetched", disk_gaps);
    end
    if (led_fdd !== 1'b0) fail("the floppy lamp lit for a CD transfer");
    expect_hold(1'b0, h_end_cyc, HOLD - 4, HOLD + 4, "READ(10)");

    // ---- 5. floppy READ DATA: both lamps ----
    disk_gaps = 0;
    fdc_read_data(t1);
    if (disk_gaps != 0) begin
      errors++; $display("FAIL: the access lamp (LED_DISK) was dark for %0d clk inside the floppy READ DATA", disk_gaps);
    end
    if (fdd_gaps != 0) begin
      errors++; $display("FAIL: the floppy lamp (LED_USER) was dark for %0d clk inside READ DATA", fdd_gaps);
    end
    expect_hold(1'b0, t1, HOLD - 8, HOLD + 4, "READ DATA, the access lamp");
    if (led_fdd !== 1'b0) fail("the floppy lamp outlived the access lamp");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_DISK_LED: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_DISK_LED: FAIL (%0d errors)", errors);
  end

  initial begin
    #100_000_000;
    $fatal(1, "TB_PC9821_DISK_LED: TIMEOUT");
  end

endmodule
