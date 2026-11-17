// tb_pc9821_ata_identify — the 256-word IDENTIFY page against the machine's capture.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_IDENTIFY:
// The ATA IDENTIFY DEVICE page against the machine's own capture (docs/probes/IDE.TXT IDW rows): at the captured drive's 7,880,544-sector capacity and its post-BIOS 8-head/17-sector geometry every one of the 256 words is compared with the capture, the model-specific identity words (serial, firmware, model) carry the core's own documented Quantum identity, the vendor words 7/8 stay 0 (single-sample convention), and the capability words that would advertise a feature the PIO-only core cannot execute (DMA/UDMA in words 49/53/62/63/65-68/88, the security/CFA words, and word 82's extra command bits) stay at the core's honest value with the multiple-mode words 47/59 withdrawn; word 255 is recomputed as the ATA integrity word (0xA5 signature plus the two's-complement checksum over the core's own 255 words) instead of copying the capture's E9; then a non-default INITIALIZE DEVICE PARAMETERS to 16 heads/63 sectors is issued and words 54/55/56/57/58 are asserted against the bench's own integer division floor(capacity/(heads*sectors)) and current capacity equal to that times heads times sectors. Taking the whole page leaves the Sector Count register at FF over a preloaded 0x5A, as the Xe10's drive does (docs/probes/XE10Y-XE10-K3M.TXT IDENT cmd=EC tf2), where NP2kai leaves the count alone for 0xEC (cbus/ideio.c ideio_r16). Words 60/61 are the LBA28 sector count, the capacity itself up to 0x0FFFFFFF and 0x0FFFFFFF above it (ATA/ATAPI-6's maximum for those words; NP2kai ideio.c's 48-bit build clamps the same way), checked at 0x0FFFFFFE, 0x0FFFFFFF, 2^28 and 2^32-1 sectors.

module tb_pc9821_ata_identify;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] io_dout;
  reg mounted = 1;
  reg readonly = 0;
  reg [31:0] capacity = 32'd7880544;   // the captured drive's 0x783F60 sectors
  wire block_read;
  wire block_write;
  wire [31:0] block_lba;
  reg block_done = 0, block_error = 0, block_buf_we = 0;
  reg [7:0] block_buf_addr = 0;
  reg [15:0] block_buf_data = 0;
  reg [7:0] block_rd_addr = 0;
  wire [15:0] block_rd_data;
  wire irq;

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
      .irq(irq)
  );

  integer errors = 0, cases = 0;
  integer n, j;
  reg [7:0] value;
  reg [15:0] word_value;
  reg [31:0] want32;

  // ==== the expected page ====
  // The machine's captured IDW rows (docs/probes/IDE.TXT:66-330) for its
  // 7,880,544-sector drive, with three classes of documented substitution:
  //  - model-specific identity (serial 10-19, firmware 23-26, model 27-46): the
  //    core's own NP2kai Quantum identity, not the captured CF card's;
  //  - vendor words 7/8: a single-sample capacity convention, left 0;
  //  - capability words the PIO-only core cannot execute (DMA/UDMA in 49/53/62/
  //    63/65-68/88, security/CFA in 89/90/92/128/160/163, word 82's extra command
  //    bits, and the withdrawn multiple-mode words 47/59): kept at the core's
  //    honest value (tb_pc9821_ata_advertised pins advertised => executable).
  reg [15:0] want [0:255];
  reg [7:0] chk;

  task fail(input [8*96-1:0] message);
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

  task read_word(output [15:0] data);
    reg [7:0] lo, hi;
    begin
      read_byte(16'h0640, lo);
      read_byte(16'h0641, hi);
      data = {hi, lo};
    end
  endtask

  // ==== CHECKS ====
  // The bench's own integer division, never a value read out of the RTL: word 54
  // is the current-cylinder count floor(capacity/(heads*sectors)) clamped to 16
  // bits, and words 57/58 are that count times heads times sectors.
  function [15:0] want_cylinders(input [31:0] cap, input [31:0] heads, input [31:0] sectors);
    reg [31:0] q;
    begin
      q = cap / (heads * sectors);
      if (q > 32'd65535) q = 32'd65535;
      want_cylinders = q[15:0];
    end
  endfunction

  function [31:0] want_current_capacity(input [31:0] cap, input [31:0] heads, input [31:0] sectors);
    begin
      want_current_capacity = cap - (cap % (heads * sectors));
    end
  endfunction

  initial begin
    for (j = 0; j < 256; j = j + 1) want[j] = 16'h0000;

    // General config and factory-default geometry.
    want[0] = 16'h044A; want[1] = 16'h1E8A; want[3] = 16'h0010;
    want[4] = 16'h7E00; want[5] = 16'h0200; want[6] = 16'h003F;
    // Serial number (core's own Quantum identity).
    want[10] = 16'h3832; want[11] = 16'h3439; want[12] = 16'h3139;
    want[13] = 16'h3334; want[14] = 16'h3131; want[15] = 16'h3932;
    want[16] = 16'h2020; want[17] = 16'h2020; want[18] = 16'h2020;
    want[19] = 16'h2020;
    want[20] = 16'h0002; want[21] = 16'h0002; want[22] = 16'h0004;
    // Firmware revision (core's own Quantum identity).
    want[23] = 16'h4135; want[24] = 16'h552E; want[25] = 16'h3132;
    want[26] = 16'h3030;
    // Model string "QUANTUM FIREBALL CR".
    want[27] = 16'h5155; want[28] = 16'h414E; want[29] = 16'h5455;
    want[30] = 16'h4D20; want[31] = 16'h4649; want[32] = 16'h5245;
    want[33] = 16'h4241; want[34] = 16'h4C4C; want[35] = 16'h2043;
    want[36] = 16'h5220;
    want[37] = 16'h2020; want[38] = 16'h2020; want[39] = 16'h2020;
    want[40] = 16'h2020; want[41] = 16'h2020; want[42] = 16'h2020;
    want[43] = 16'h2020; want[44] = 16'h2020; want[45] = 16'h2020;
    want[46] = 16'h2020;
    // Capabilities: LBA (w49), PIO timing (w51), field validity bits 0/1 (w53).
    want[49] = 16'h0200; want[51] = 16'h0200; want[53] = 16'h0003;
    // Current geometry: the machine's post-BIOS 8 heads / 17 sectors.
    want[54] = 16'hE259; want[55] = 16'h0008; want[56] = 16'h0011;
    want[57] = 16'h3F48; want[58] = 16'h0078;
    // Total LBA capacity.
    want[60] = 16'h3F60; want[61] = 16'h0078;
    want[64] = 16'h0003;   // PIO modes 3,4
    want[82] = 16'h4200;   // NOP, DEVICE RESET, Write Cache
    want[93] = 16'h4000;   // power-on diagnostics passed
    want[217] = 16'h0001;  // non-rotating media

    // Word 255: the ATA integrity word over the core's own 255 words, computed
    // here with the bench's own byte sum (0xA5 signature + two's-complement).
    chk = 8'h00;
    for (j = 0; j < 255; j = j + 1)
      chk = chk - want[j][7:0] - want[j][15:8];
    chk = chk - 8'hA5;
    want[255] = {chk, 8'hA5};

    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    // The divider needs two 32-clock passes after reset/capacity, so wait well
    // past both before the first IDENTIFY.
    repeat (80) @(posedge clk);
    write_byte(16'h0432, 8'h00);   // select the bank the interface is on

    // ---- 1. the captured page (default 8 heads / 17 sectors) ----
    write_byte(16'h064E, 8'hEC);   // IDENTIFY DEVICE
    read_byte(16'h074C, value);
    if (value !== 8'h58) fail("IDENTIFY did not raise DRQ (status)");
    for (n = 0; n < 256; n = n + 1) begin
      read_word(word_value);
      cases = cases + 1;
      if (word_value !== want[n]) begin
        $display("  IDENTIFY word %0d: rtl=0x%04x want=0x%04x", n, word_value, want[n]);
        fail("IDENTIFY word mismatch");
      end
    end

    // ---- 2. non-default INITIALIZE DEVICE PARAMETERS (16 heads / 63 sectors) ----
    write_byte(16'h0644, 8'd63);   // sectors per track
    write_byte(16'h064C, 8'h0F);   // highest head number = 15 -> 16 heads
    write_byte(16'h064E, 8'h91);   // INITIALIZE DEVICE PARAMETERS
    read_byte(16'h064E, value);    // acknowledge the command IRQ
    repeat (80) @(posedge clk);    // the geometry change reruns the divider

    write_byte(16'h064E, 8'hEC);   // IDENTIFY DEVICE again
    read_byte(16'h074C, value);
    if (value !== 8'h58) fail("second IDENTIFY did not raise DRQ (status)");
    want32 = want_current_capacity(32'd7880544, 32'd16, 32'd63);
    for (n = 0; n < 256; n = n + 1) begin
      read_word(word_value);
      if (n == 54 && word_value !== want_cylinders(32'd7880544, 32'd16, 32'd63)) begin
        $display("  IDP word 54: rtl=0x%04x want=0x%04x", word_value,
                 want_cylinders(32'd7880544, 32'd16, 32'd63));
        fail("word 54 not recomputed at the adopted geometry");
      end
      if (n == 55 && word_value !== 16'd16) fail("word 55 not the adopted heads");
      if (n == 56 && word_value !== 16'd63) fail("word 56 not the adopted sectors");
      if (n == 57 && word_value !== want32[15:0]) begin
        $display("  IDP word 57: rtl=0x%04x want=0x%04x", word_value, want32[15:0]);
        fail("word 57 not the adopted geometry's capacity");
      end
      if (n == 58 && word_value !== want32[31:16]) begin
        $display("  IDP word 58: rtl=0x%04x want=0x%04x", word_value, want32[31:16]);
        fail("word 58 not the adopted geometry's capacity");
      end
    end

    // ---- 3. the page leaves the Sector Count at FF ----
    // The Xe10's drive reads SC 00 at DRQ and FF once the page has been taken, from a preload
    // of 5A (docs/probes/XE10Y-XE10-K3M.TXT:42 `tf1=00.00.A5.3C.C3.A0.58.00.58
    // tf2=00.FF.A5.3C.C3.A0.50.00.50`). NP2kai's ideio_r16 leaves the count alone for 0xEC;
    // the capture outranks it.
    write_byte(16'h0644, 8'h5A);
    write_byte(16'h064E, 8'hEC);   // IDENTIFY DEVICE a third time
    read_byte(16'h074C, value);
    if (value !== 8'h58) fail("third IDENTIFY did not raise DRQ (status)");
    for (n = 0; n < 256; n = n + 1) read_word(word_value);
    read_byte(16'h074C, value);
    if (value !== 8'h50) fail("the IDENTIFY page did not end (status after the last word)");
    read_byte(16'h0644, value);
    cases = cases + 1;
    if (value !== 8'hFF) begin
      $display("  Sector Count after IDENTIFY: rtl=0x%02x want=0xff", value);
      fail("IDENTIFY did not leave the Sector Count at FF (K3M capture)");
    end

    // ---- 4. words 60/61 are the LBA28 count, at most 0x0FFFFFFF ----
    // ATA/ATAPI-6 (words 60-61, total number of user addressable sectors for the 28-bit
    // commands): the maximum value is 0FFFFFFFh. NP2kai ideio.c's 48-bit build clamps the same
    // way (`tmp[60] = (UINT16)0xffff; tmp[61] = (UINT16)0xfff;` once the count needs more than
    // 28 bits). Below the limit the word is the capacity itself.
    // FAIL-FIRST: the words carried the image's 32-bit sector count unclamped.
    for (j = 0; j < 4; j = j + 1) begin
      case (j)
        0: want32 = 32'h0FFF_FFFE;
        1: want32 = 32'h0FFF_FFFF;
        2: want32 = 32'h1000_0000;
        default: want32 = 32'hFFFF_FFFF;
      endcase
      capacity = want32;
      repeat (80) @(posedge clk);  // the divider reruns on the capacity change
      write_byte(16'h064E, 8'hEC);
      read_byte(16'h074C, value);
      if (value !== 8'h58) fail("IDENTIFY (large capacity) did not raise DRQ (status)");
      if (want32 > 32'h0FFF_FFFF) want32 = 32'h0FFF_FFFF;
      for (n = 0; n < 256; n = n + 1) begin
        read_word(word_value);
        if ((n == 60 && word_value !== want32[15:0]) || (n == 61 && word_value !== want32[31:16])) begin
          $display("  capacity 0x%08x word %0d: rtl=0x%04x want=0x%04x", capacity, n, word_value,
                   (n == 60) ? want32[15:0] : want32[31:16]);
          fail("words 60/61 are not the LBA28 count (clamped to 0x0FFFFFFF)");
        end
      end
      cases = cases + 1;
    end
    capacity = 32'd7880544;

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_ATA_IDENTIFY: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATA_IDENTIFY: FAIL (%0d errors)", errors);
  end

  initial begin
    #4_000_000;
    $fatal(1, "TB_PC9821_ATA_IDENTIFY: TIMEOUT");
  end

endmodule
