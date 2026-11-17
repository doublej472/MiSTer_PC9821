// tb_pc9821_ata_multiple — ATA multiple mode: SET MULTIPLE MODE and READ MULTIPLE.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_MULTIPLE:
// ATA multiple-block mode, which NP2kai's IDENTIFY page advertises (word 47 = 0x8080) and the xe10 IDE option ROM drives: SET MULTIPLE MODE, tried at every count 0..255, accepts exactly 2/4/8/16/32/64/128 and ABRTs any other (NP2kai ideio.c case 0xc6), READ MULTIPLE serves its sectors byte-exact while raising the data interrupt once per negotiated BLOCK, and WRITE MULTIPLE (0xC5) drains its sectors byte-exact with the reference's block-end cadence (four sectors in a block of 2 raise two interrupts, because the final sector always interrupts); a partial final block (three sectors in a block of 2) raises NP2kai's two interrupts on both (readsec at in-block count 0, writesec at each block end plus the final sector). It also asserts the model's streaming limit, a documented divergence from NP2kai (whose synchronous image read serves a whole block before its interrupt) and the reason IDENTIFY word 47 withdraws the multiple advertisement: a host that takes the block's one interrupt and then streams the whole 2-sector block without checking DRQ, as the Xe10 ROM does, reads the first sector's 256 words byte-exact with DRQ set and then exactly 256 words of 0x0000 with DRQ clear while the second sector's fetch stalls - no stale or shifted data, and no 0x0000 while DRQ is set.

module tb_pc9821_ata_multiple;

  localparam [31:0] LBA_BASE = 32'h0200;
  localparam [31:0] LBA_W    = 32'h0300;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] io_dout;
  reg mounted = 1, readonly = 0;
  reg [31:0] capacity = 32'd100000;
  wire block_read, block_write;
  wire [31:0] block_lba;
  reg block_done = 0, block_error = 0, block_buf_we = 0;
  reg [7:0] block_buf_addr = 0;
  reg [15:0] block_buf_data = 0;
  reg [7:0] block_rd_addr = 0;
  wire [15:0] block_rd_data;
  wire irq;
  wire [7:0] dbg_state;
  wire [31:0] dbg_cmd;

  // ==== DUT ====
  pc9821_ata dut (
      // The channel's slave (device 1): no image, so the master answers for DEV=1 as before.

      .clk(clk),
      .rst_n(rst_n),
      .io_rd(io_rd),
      .io_wr(io_wr),
      .io_addr(io_addr),
      .io_din(io_din),
      .io_dout(io_dout),
      .mounted(mounted),
      .readonly(readonly),
      .capacity(capacity),
      .block_read(block_read),
      .block_write(block_write),
      .block_lba(block_lba),
      .block_done(block_done),
      .block_error(block_error),
      .block_buf_we(block_buf_we),
      .block_buf_addr(block_buf_addr),
      .block_buf_data(block_buf_data),
      .block_rd_addr(block_rd_addr),
      .block_rd_data(block_rd_data),
      .irq(irq),
      .dbg_state(dbg_state),
      .dbg_cmd(dbg_cmd)
  );

  integer errors = 0;
  integer n, s, w;
  reg [7:0] value;
  reg [15:0] word_value;
  integer irq_count = 0;
  reg irq_prev = 0;

  // ==== CHECKS ====
  always @(posedge clk) begin
    irq_prev <= irq;
    if (irq && !irq_prev) irq_count = irq_count + 1;
  end

  task fail(input [8*128-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task write_byte(input [15:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr;
      io_din  = data;
      io_wr   = 1;
      @(posedge clk);
      @(negedge clk);
      io_wr = 0;
      // The guest's next access comes at least five clk_sys after a command's (pc9821_iobus
      // S_BYTE -> S_REPLY -> S_HOLD -> S_IDLE -> S_IOWAIT -> S_BYTE), and a media command
      // dispatches pc9821_ata's MEDIA_WAIT cycles after its write: look no sooner than the bus.
      if (addr == 16'h064E) repeat (4) @(negedge clk);
    end
  endtask

  task read_byte(input [15:0] addr, output [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr;
      io_rd   = 1;
      #1 data = io_dout;
      @(posedge clk);
      @(negedge clk);
      io_rd = 0;
    end
  endtask

  task read_pio_word(output [15:0] data);
    reg [7:0] lo, hi;
    begin
      read_byte(16'h0640, lo);
      read_byte(16'h0641, hi);
      data = {hi, lo};
    end
  endtask

  task write_pio_word(input [15:0] data);
    begin
      write_byte(16'h0640, data[7:0]);
      write_byte(16'h0641, data[15:8]);
    end
  endtask

  // Sector byte N is LBA[7:0] XOR N[7:0]; word i is {LBA ^ (2i+1), LBA ^ (2i)}.
  // The same synthetic map tb_pc9821_ata and tb_pc9821_ata_readahead use, so a
  // wrong LBA is a data mismatch rather than a silent pass.
  function [15:0] sector_word_for(input [31:0] lba, input [7:0] index);
    begin
      sector_word_for = {
          lba[7:0] ^ {index[6:0], 1'b1},
          lba[7:0] ^ {index[6:0], 1'b0}
      };
    end
  endfunction

  task wait_drq;
    begin
      n = 0;
      while (!dut.status_reg[3] && n < 200000) begin
        @(posedge clk);
        n = n + 1;
      end
      if (!dut.status_reg[3]) fail("ATA DRQ timeout");
    end
  endtask

  // One DRQ's worth of data: 256 words per sector, addressed from `lba`. The
  // trailing 0x064E read is the guest's acknowledge, which drops the interrupt
  // line so the NEXT block boundary is a fresh rising edge.
  task read_sector(input [31:0] lba);
    begin
      wait_drq;
      for (w = 0; w < 256; w = w + 1) begin
        read_pio_word(word_value);
        if (word_value !== sector_word_for(lba, w[7:0]))
          fail("READ MULTIPLE sector data");
      end
      read_byte(16'h064E, value);
    end
  endtask

  // The write mirror: one DRQ's worth of 256 words handed to the drive.
  task write_sector(input [31:0] lba);
    begin
      wait_drq;
      for (w = 0; w < 256; w = w + 1)
        write_pio_word(sector_word_for(lba, w[7:0]));
      read_byte(16'h064E, value);
    end
  endtask

  // ==== block adapter ====
  // One request / one completion pulse, 256 words streamed in, with a short
  // latency so the transfer is not the bench's bottleneck. The write direction
  // drains the sector buffer through the read port the drive muxes for it and
  // compares against the same synthetic map, so a wrong sector or a dropped word
  // is a data mismatch.
  reg        ad_active = 0;
  reg [31:0] ad_lba = 0;
  integer    ad_wait = 0;
  integer    ad_lat = 4;   // fetch latency; raised by the streaming-limit case
  integer    ad_index = 0;
  integer    ad_reqs = 0;
  reg        drain_active = 0;
  integer    ad_writes = 0;
  integer    write_errors = 0;

  always @(negedge clk) begin
    block_done   = 0;
    block_buf_we = 0;
    if (!ad_active) begin
      if (block_read) begin
        ad_active = 1;
        ad_lba    = block_lba;
        ad_wait   = ad_lat;
        ad_index  = 0;
        ad_reqs   = ad_reqs + 1;
      end
    end else if (ad_wait != 0) begin
      ad_wait = ad_wait - 1;
    end else begin
      block_buf_we   = 1;
      block_buf_addr = ad_index[7:0];
      block_buf_data = sector_word_for(ad_lba, ad_index[7:0]);
      if (ad_index == 255) begin
        ad_active  = 0;
        block_done = 1;
      end else ad_index = ad_index + 1;
    end

    if (!drain_active && block_write) begin
      drain_active  = 1;
      block_rd_addr = 8'd0;
      ad_writes     = ad_writes + 1;
    end else if (drain_active) begin
      // block_rd_data is combinational from the address presented last cycle.
      if (block_rd_data !== sector_word_for(block_lba, block_rd_addr))
        write_errors = write_errors + 1;
      if (block_rd_addr == 8'd255) begin
        drain_active = 0;
        block_done   = 1;
      end else block_rd_addr = block_rd_addr + 8'd1;
    end
  end

  task set_multiple(input [7:0] count);
    begin
      write_byte(16'h0644, count);
      write_byte(16'h064E, 8'hC6);
    end
  endtask

  initial begin
    #100;
    rst_n = 1;
    repeat (4) @(negedge clk);

    // Select the hard disk's bank, bank 0 (0x0432 bit 0 is the connection test;
    // device_present follows it).
    write_byte(16'h0432, 8'h00);

    // ---- 1. SET MULTIPLE MODE: the negotiated counts are accepted ----
    set_multiple(8'd2);
    if (dut.status_reg !== 8'h50 || dut.error_reg !== 8'h00)
      fail("SET MULTIPLE 2 was not accepted");
    if (!irq) fail("SET MULTIPLE 2 raised no interrupt");

    // ---- 2. SET MULTIPLE MODE: any other count is ABRT (NP2kai's default arm) ----
    read_byte(16'h064E, value);
    set_multiple(8'd3);
    if (dut.status_reg !== 8'h41 || dut.error_reg !== 8'h04)
      fail("SET MULTIPLE 3 was not rejected with ABRT");
    if ((dbg_cmd[3:0]) !== 4'd5)
      fail("SET MULTIPLE 3 recorded the wrong abort reason");

    // ---- 3. READ MULTIPLE, block of 2, two sectors ----
    // ONE interrupt for the whole block: NP2kai raises it while its in-block
    // counter is zero, and a 2-sector transfer of a 2-sector block crosses the
    // boundary once. (The block length is the 2 negotiated above.)
    read_byte(16'h064E, value);
    irq_count = 0;
    write_byte(16'h064C, 8'hA0);          // LBA mode, drive 0
    write_byte(16'h0646, LBA_BASE[7:0]);  // sector number
    write_byte(16'h0648, LBA_BASE[15:8]); // cylinder low
    write_byte(16'h064A, LBA_BASE[23:16]);// cylinder high
    write_byte(16'h064C, 8'hE0);          // LBA, drive 0
    write_byte(16'h0644, 8'd2);           // two sectors
    write_byte(16'h064E, 8'hC4);          // READ MULTIPLE
    if (dut.status_reg[0] || dut.error_reg !== 8'h00)
      fail("READ MULTIPLE was aborted");
    read_sector(LBA_BASE);
    read_sector(LBA_BASE + 32'd1);
    while (dut.status_reg[7]) @(negedge clk);
    if (dut.status_reg !== 8'h50)
      fail("READ MULTIPLE did not complete with READY|DSC");
    if (irq_count !== 1)
      fail("READ MULTIPLE of one block raised more than one interrupt");

    // ---- 4. READ MULTIPLE, block of 2, four sectors: two block boundaries ----
    write_byte(16'h0646, LBA_BASE[7:0]);
    write_byte(16'h0644, 8'd4);
    irq_count = 0;
    write_byte(16'h064E, 8'hC4);
    for (s = 0; s < 4; s = s + 1) read_sector(LBA_BASE + s[31:0]);
    while (dut.status_reg[7]) @(negedge clk);
    if (dut.status_reg !== 8'h50)
      fail("four-sector READ MULTIPLE did not complete");
    if (irq_count !== 2)
      fail("four-sector READ MULTIPLE with a block of 2 did not raise two interrupts");
    if (ad_reqs < 6)
      fail("the block adapter was not asked for every sector");

    // ---- 5. WRITE MULTIPLE (0xC5), block of 2, four sectors ----
    // The write sibling of READ MULTIPLE. NP2kai's cadence is the other way
    // round (`writesec` increments its in-block counter and THEN tests it), so
    // the interrupt is at the END of a block and the final sector always
    // interrupts: four sectors in a block of 2 raise two.
    read_byte(16'h064E, value);
    irq_count = 0;
    write_byte(16'h064C, 8'hA0);           // LBA mode, drive 0
    write_byte(16'h0646, LBA_W[7:0]);
    write_byte(16'h0648, LBA_W[15:8]);
    write_byte(16'h064A, LBA_W[23:16]);
    write_byte(16'h064C, 8'hE0);           // LBA, drive 0
    write_byte(16'h0644, 8'd4);            // four sectors
    write_byte(16'h064E, 8'hC5);           // WRITE MULTIPLE
    if (dut.status_reg[0] || dut.error_reg !== 8'h00)
      fail("WRITE MULTIPLE was aborted");
    for (s = 0; s < 4; s = s + 1) write_sector(LBA_W + s[31:0]);
    // The final completion and its interrupt land after the last word; the edge
    // counter is registered, so give it a cycle before reading it.
    while (dut.status_reg[7]) @(negedge clk);
    repeat (4) @(negedge clk);
    if (dut.status_reg !== 8'h50)
      fail("four-sector WRITE MULTIPLE did not complete");
    if (irq_count !== 2)
      fail("four-sector WRITE MULTIPLE with a block of 2 did not raise two interrupts");
    if (ad_writes !== 4)
      fail("the block adapter did not drain every WRITE MULTIPLE sector");
    if (write_errors != 0)
      fail("WRITE MULTIPLE drain pattern mismatch");

    // ---- 5b. SET MULTIPLE MODE over every count, against NP2kai's accept set ----
    // cbus/ideio.c case 0xc6: `case 2: case 4: case 8: case 16: case 32: case 64: case 128:`
    // set mulmode (IDEIO_MULTIPLE_MAX is 128); every other count falls to `default: cmdabort`
    // (STATUS DRDY|ERR 0x41, ERROR ABRT 0x04).
    begin : accept_set
      integer c, bad;
      bad = 0;
      for (c = 0; c < 256; c = c + 1) begin
        read_byte(16'h064E, value);
        set_multiple(c[7:0]);
        if (c == 2 || c == 4 || c == 8 || c == 16 || c == 32 || c == 64 || c == 128) begin
          if (dut.status_reg !== 8'h50 || dut.error_reg !== 8'h00) begin
            if (bad < 4) $display("FAIL: SET MULTIPLE %0d was not accepted (status %02x error %02x)",
                                  c, dut.status_reg, dut.error_reg);
            bad = bad + 1;
          end
        end else if (dut.status_reg !== 8'h41 || dut.error_reg !== 8'h04) begin
          if (bad < 4) $display("FAIL: SET MULTIPLE %0d was not rejected with ABRT (status %02x error %02x)",
                                c, dut.status_reg, dut.error_reg);
          bad = bad + 1;
        end
      end
      if (bad != 0) fail("SET MULTIPLE's accept set is not NP2kai's 2/4/8/16/32/64/128");
    end

    // ---- 5c. A partial final block: three sectors in a block of 2 ----
    // NP2kai readsec interrupts while its in-block counter is 0 (sectors 0 and 2: two), and
    // writesec at each block's end plus the final sector (after sector 1, and the last: two).
    read_byte(16'h064E, value);
    set_multiple(8'd2);
    if (dut.status_reg !== 8'h50) fail("SET MULTIPLE 2 (partial-block cases) was not accepted");
    read_byte(16'h064E, value);
    write_byte(16'h064C, 8'hE0);
    write_byte(16'h0646, LBA_BASE[7:0]);
    write_byte(16'h0648, LBA_BASE[15:8]);
    write_byte(16'h064A, LBA_BASE[23:16]);
    write_byte(16'h0644, 8'd3);
    irq_count = 0;
    write_byte(16'h064E, 8'hC4);
    for (s = 0; s < 3; s = s + 1) read_sector(LBA_BASE + s[31:0]);
    while (dut.status_reg[7]) @(negedge clk);
    repeat (4) @(negedge clk);
    if (dut.status_reg !== 8'h50)
      fail("three-sector READ MULTIPLE did not complete");
    if (irq_count !== 2)
      fail("three-sector READ MULTIPLE with a block of 2 did not raise two interrupts");

    read_byte(16'h064E, value);
    write_errors = 0;
    ad_writes = 0;
    write_byte(16'h064C, 8'hE0);
    write_byte(16'h0646, LBA_W[7:0]);
    write_byte(16'h0648, LBA_W[15:8]);
    write_byte(16'h064A, LBA_W[23:16]);
    write_byte(16'h0644, 8'd3);
    irq_count = 0;
    write_byte(16'h064E, 8'hC5);
    for (s = 0; s < 3; s = s + 1) write_sector(LBA_W + s[31:0]);
    while (dut.status_reg[7]) @(negedge clk);
    repeat (4) @(negedge clk);
    if (dut.status_reg !== 8'h50)
      fail("three-sector WRITE MULTIPLE did not complete");
    if (irq_count !== 2)
      fail("three-sector WRITE MULTIPLE with a block of 2 did not raise two interrupts");
    if (ad_writes !== 3)
      fail("the block adapter did not drain every three-sector WRITE MULTIPLE sector");
    if (write_errors != 0)
      fail("three-sector WRITE MULTIPLE drain pattern mismatch");

    // ---- 6. The streaming limit: why word 47 advertises no multiple mode ----
    // The Xe10 ROM's READ MULTIPLE handler (BANK3 0x9603) waits for ONE interrupt
    // and then consumes 256*M words with `rep insw`, never checking DRQ. With the
    // HPS fetch slower than the PIO drain the model drops DRQ mid-block, and the
    // ATA rule for the data port with DRQ clear is 0x00 - so a host that reads
    // ahead of the data gets 0x00 spliced into the block. This case drives exactly
    // that shape and asserts, word by word, that the model answers 0x00 rather than
    // stale data, which is the measured reason IDENTIFY word 47 advertises no
    // multiple mode.
    // A KNOWN DIVERGENCE from NP2kai, asserted as the model's own contract: NP2kai's image
    // read is synchronous, so its block is whole before the interrupt; this model buffers
    // one sector and fetches the next during the drain, so the ROM's DRQ-blind `rep insw`
    // outruns it. What is pinned is that the outrun is CLEAN: sector 0 exact, then 0x0000
    // for every word read while DRQ is clear, and nothing read while DRQ is set is 0x0000.
    ad_lat = 8000;                       // a fetch slower than the whole block drain
    set_multiple(8'd2);
    read_byte(16'h064E, value);
    irq_count = 0;
    write_byte(16'h064C, 8'hE0);
    write_byte(16'h0646, LBA_W[7:0]);
    write_byte(16'h0648, LBA_W[15:8]);
    write_byte(16'h064A, LBA_W[23:16]);
    write_byte(16'h0644, 8'd4);
    write_byte(16'h064E, 8'hC4);         // READ MULTIPLE, block of 2, 4 sectors
    begin : stream_limit
      integer k; integer zeros; integer served; integer bad_served; integer bad_zero;
      reg drq_at_read;
      zeros = 0; served = 0; bad_served = 0; bad_zero = 0;
      // The ROM's shape: ONE interrupt for the block (the first sector's), then 256*M words.
      n = 0;
      while (!irq && n < 200000) begin
        @(negedge clk);
        n = n + 1;
      end
      if (!irq) fail("the streamed READ MULTIPLE never raised its block interrupt");
      for (k = 0; k < 512; k = k + 1) begin
        // DRQ only changes on a 0x0641 read (the word's second lane), so its value before
        // the word is the value both lanes see.
        drq_at_read = dut.status_reg[3];
        read_pio_word(word_value);
        if (drq_at_read) begin
          if (word_value !== sector_word_for(LBA_W + (served / 256), served[7:0]))
            bad_served = bad_served + 1;
          served = served + 1;
        end else begin
          if (word_value !== 16'h0000) bad_zero = bad_zero + 1;
          zeros = zeros + 1;
        end
      end
      $display("NOTE ata_multiple: KNOWN-DIVERGENCE (np2kai serves the whole block) streamed block: %0d words served with DRQ (%0d wrong), %0d read with DRQ clear (%0d not 0x0000) - the reason word 47 is withdrawn",
               served, bad_served, zeros, bad_zero);
      if (served != 256)
        fail("the streamed block did not serve exactly the first sector's 256 words with DRQ set");
      if (bad_served != 0)
        fail("a word read with DRQ set was not the block's next word (stale or shifted data)");
      if (zeros != 256)
        fail("the stalled second sector did not read as exactly 256 DRQ-clear words");
      if (bad_zero != 0)
        fail("a word read with DRQ clear was not 0x0000");
    end
    // Abandon and drain the half-served block, then restore the fast adapter.
    ad_lat = 4;
    write_byte(16'h074C, 8'h04);
    write_byte(16'h074C, 8'h00);
    n = 0;
    while (dut.xfer_state !== 3'd0 && n < 40000) begin
      @(negedge clk);
      n = n + 1;
    end
    if (dut.xfer_state !== 3'd0) fail("the abandoned streamed block did not drain");

    // ---- 8. SET MULTIPLE MODE 128 (the NP2kai maximum; word 47 no longer advertises it) ----
    read_byte(16'h064E, value);
    set_multiple(8'd128);
    if (dut.status_reg !== 8'h50 || dut.error_reg !== 8'h00)
      fail("SET MULTIPLE 128 was not accepted");

    // ---- verdict ----
    // ==== VERDICT ====
    if (errors == 0) begin
      $display("NOTE ata_multiple: SET MULTIPLE accepts exactly 2/4/8/16/32/64/128 of 0..255; READ MULTIPLE served 2, 4 and 3 sectors and WRITE MULTIPLE drained 4 and 3 with NP2kai's per-block interrupts in a block of 2");
      $display("TB_PC9821_ATA_MULTIPLE: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_ATA_MULTIPLE: FAIL (%0d errors)", errors);
    end
  end

  initial begin
    #5000000;
    $fatal(1, "TB_PC9821_ATA_MULTIPLE: FAIL (timeout)");
  end

endmodule
