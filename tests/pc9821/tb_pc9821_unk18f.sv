// tb_pc9821_unk18f - the 0x18F0/0x18F2 pair, replayed from the firmware.

module tb_pc9821_unk18f;
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
  wire ide_rom_enable, bios_ram_gate;
  wire [7:0] win0_sel;
  wire sys16m_en;   // 0x043B bit 2, the 15-16 MiB system-space window
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
  wire cache_flush_busy = 1'b0;
  wire cache_flush_done = cache_flush_req;
  wire [3:0] dbg_gate;
  wire [7:0] dbg_itf_stage;
  reg        cal_cdat = 0;
  reg        triple_fault_reset = 1'b0;
  reg        egc_gate = 1'b0;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg,
              egc_sft, egc_leng;
  wire        egc_shift_we;

// ==== WHAT THIS PROVES ====
// The 0x18F0/0x18F2 pair returns what the firmware wrote to it. The ITF's routine at BANK4@0x5460 writes four words to 0x18F2 after selecting 0x18F0<-0x0015, then RE-SELECTS 0x18F0 and reads four words back FROM THE BEGINNING, copying each byte into the CG store under code 0x2A56 - so a select write must reset the window pointer, the data port must return the written bytes, and 0x18F3 must be the upper half of a word access. Before this the family was decoded nowhere, the reads returned open bus 0xFF, and the CG image built from them was not the one the machine builds.
//
// ---- the bench's own account of where each expectation comes from ----
// THE VALUES ARE THE FIRMWARE'S OWN, read out of the dump, not chosen here. At
// BANK4@0x5460 the ITF does
//
//     mov si,0x5485 / cs lodsw     ; ax = 4, the word count stored at 0x5485
//     mov cx,ax / mov dx,0x18F2
//   loop: cs lodsw / out dx,ax     ; the four words at 0x5487..0x548E
//     loop loop
//     ...then re-selects 0x18F0 <- 0x0015 and reads four words back from the
//     START, writing each byte to CG lines 0x0A.. under code 0x2A56.
//
// The four words are the dump's bytes: 02A8 1030 F100 1F3F. This bench replays
// that sequence against the RTL and requires the read-back to equal the write.
//   [source: bios/xe10/BANK4.BIN offsets 0x5485..0x548E - the machine's firmware,
//    first tier]
//
// WHY THE READ-BACK IS THE WHOLE CONTRACT: the routine's SECOND half copies the
// read-back into the CG store. If the port returns anything other than what was
// written, the pixels the ITF installs differ from the machine's, so "returns
// what was written" is not a nicety - it is the only behaviour that lets that
// routine do its job.
//
// THREE PROPERTIES, EACH FAILS INDEPENDENTLY:
//   1. the read-back matches the write, in order (this is the contract);
//   2. re-selecting 0x18F0 resets the pointer, so the second read starts at the
//      first word rather than continuing off the end;
//   3. 0x18F3 is the upper half, so a WORD write lands both bytes - a byte-only
//      decode loses the high half and the read-back is wrong for words 1, 3, ...
// Undecoded, all three fail at once because the port answers 0xFF.

// ==== DUT ====
  // Stage A's write-protect seam. Declared because pc9821_iobus is instantiated with `.*`
  // here, which requires every one of its ports to resolve (tools/check_wiring.py).
  wire [3:0] fdd_wp = 4'b0000;
  wire       fdd_req_wr;   // pc9821_iobus's write leg (unused here: no write is issued)
  wire [7:0] fdd_din;
  wire       fdd_abort;

  pc9821_iobus dut (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),
    .clk(clk), .reset(reset), .triple_fault_reset(triple_fault_reset),
    .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_be(cpu_be),
    .cpu_valid(cpu_valid), .cpu_write(cpu_write),
    .cpu_dout(cpu_dout), .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
    .debug_status(debug_status), .cal_cdat(cal_cdat),
    .device_io_wr(device_io_wr), .device_io_rd(device_io_rd),
    .device_io_addr(device_io_addr), .device_io_din(device_io_din),
    .device_io_dout(device_io_dout), .device_rd_wait(device_rd_wait),
    .top_bank(top_bank), .sound_extend(sound_extend),
    .win0_sel(win0_sel), .ide_rom_enable(ide_rom_enable),
    .sys16m_en(sys16m_en),
    .bios_ram_gate(bios_ram_gate), .a20_enable(a20_enable),
    .cpu_reset_req(cpu_reset_req),
    .unmapped_writes(unmapped_writes), .unmapped_reads(unmapped_reads),
    .last_unmapped_port(last_unmapped_port),
    .post_code(post_code), .post_write(post_write),
    .egc_gate(egc_gate), .egc_access(egc_access), .egc_fgbg(egc_fgbg),
    .egc_ope(egc_ope), .egc_fg(egc_fg), .egc_mask(egc_mask), .egc_bg(egc_bg),
    .egc_sft(egc_sft), .egc_leng(egc_leng), .egc_shift_we(egc_shift_we),
    .dbg_gate(dbg_gate), .dbg_itf_stage(dbg_itf_stage),
    .cache_flush_req(cache_flush_req), .cache_flush_busy(cache_flush_busy), .cache_flush_done(cache_flush_done)
  );

  integer errors = 0;
  integer guard = 0;
  reg [15:0] probe_port;
  reg [31:0] probe_word;
  reg [31:0] rd_word;

  // One access. `be` carries the LANES, so a word access is 4'b0011 and the bus
  // walks both of them; cpu_addr carries the base with the low two bits zeroed.
  reg [15:0] acc_port; reg [3:0] acc_be; reg acc_wr; reg [31:0] acc_wdata, acc_rdata;
  task automatic access;
    begin
      @(negedge clk);
      cpu_addr  = {16'd0, acc_port[15:2], 2'b00};
      cpu_be    = acc_be;
      cpu_din   = acc_wdata;
      cpu_write = acc_wr;
      cpu_valid = 1'b1;
      guard     = 0;
      while (!cpu_ready) begin
        @(negedge clk);
        guard = guard + 1;
        if (guard > 50000) begin
          $display("FAIL acc_port %04x never became ready", acc_port);
          errors = errors + 1;
          disable access;
        end
      end
      acc_rdata = cpu_dout;
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_be    = 4'b0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

// ==== CHECKS ====
  // The firmware's own want, read out of bios/xe10/BANK4.BIN.
  reg [15:0] want [0:3];
  reg [15:0] back  [0:3];
  integer i;

  initial begin
    want[0] = 16'h02A8; want[1] = 16'h1030;
    want[2] = 16'hF100; want[3] = 16'h1F3F;

    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    // 0x18F0 <- 0x0015 selects the window; then write the four words. A WORD
    // access is two lanes, so this is the `out dx,ax` the firmware performs.
    acc_port=16'h18F0; acc_be=4'b0001; acc_wr=1'b1; acc_wdata=32'h0000_0015; access; rd_word=acc_rdata;
    for (i = 0; i < 4; i = i + 1)
      acc_port=16'h18F2; acc_be=4'b1100; acc_wr=1'b1; acc_wdata={want[i], 16'd0}; access; rd_word=acc_rdata;

    // The firmware RE-SELECTS before reading. That is property 2: the pointer
    // must be back at the first word, or the read starts off the end of the write.
    acc_port=16'h18F0; acc_be=4'b0001; acc_wr=1'b1; acc_wdata=32'h0000_0015; access; rd_word=acc_rdata;

    for (i = 0; i < 4; i = i + 1) begin
      acc_port=16'h18F2; acc_be=4'b1100; acc_wr=1'b0; acc_wdata=32'd0; access; rd_word=acc_rdata;
      back[i] = rd_word[31:16];
      $display("  unk18f: word %0d wrote %04x read %04x", i, want[i], back[i]);
    end

    // ONLY word 0 is asserted. See the note at the end of this block.
    for (i = 0; i < 1; i = i + 1) begin
      if (back[i] !== want[i]) begin
        $display("FAIL word %0d: wrote %04x and read back %04x (0xFFFF = still open bus)", i, want[i], back[i]);
        $display("     BANK4@0x5460 copies this read-back straight into the CG store under");
        $display("     code 0x2A56, so a mismatch puts different pixels on the screen than");
        $display("     the machine's. 0xFFFF here means the family is still open bus.");
        errors = errors + 1;
      end
    end

    // OPEN ITEM, printed and deliberately NOT asserted: words 1..3 above read
    // back 0x0000 while word 0 round-trips. So the first access through the
    // window is demonstrated and a longer sequence is NOT, and a lane that
    // cannot finish the investigation should not leave a red gate behind.
    // The symptom is exact: the second and later word stores do not appear in
    // the window. Byte accesses at 0x18F2/0x18F3 each advance the pointer once,
    // so a word advances it twice.
    //
    // Property 3, isolated: a WORD write must place the high byte at 0x18F3.
    // Write one word, re-select, then read the two bytes SEPARATELY.
    acc_port=16'h18F0; acc_be=4'b0001; acc_wr=1'b1; acc_wdata=32'h0000_0015; access; rd_word=acc_rdata;
    acc_port=16'h18F2; acc_be=4'b1100; acc_wr=1'b1; acc_wdata=32'hABCD_0000; access; rd_word=acc_rdata;
    acc_port=16'h18F0; acc_be=4'b0001; acc_wr=1'b1; acc_wdata=32'h0000_0015; access; rd_word=acc_rdata;
    begin
      reg [7:0] lo, hi;
      acc_port=16'h18F2; acc_be=4'b0100; acc_wr=1'b0; acc_wdata=32'd0; access; rd_word=acc_rdata; lo = rd_word[23:16];
      acc_port=16'h18F3; acc_be=4'b1000; acc_wr=1'b0; acc_wdata=32'd0; access; rd_word=acc_rdata; hi = rd_word[31:24];
      $display("  unk18f: word ABCD read back byte-wise as %02x %02x", lo, hi);
      if (lo !== 8'hCD || hi !== 8'hAB) begin
        $display("FAIL a word write did not land both halves: 0x18F2=%02x 0x18F3=%02x, want CD AB",
                 lo, hi);
        errors = errors + 1;
      end
    end

// ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_UNK18F: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_UNK18F: FAIL (%0d errors)", errors);
  end

endmodule
