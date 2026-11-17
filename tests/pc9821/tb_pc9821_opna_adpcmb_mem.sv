`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_OPNA_ADPCMB_MEM: the real Xe10's XE10T /OPNA2 ADPCM-B memory-write rows hold on the core's 86-board glue, driven with the probe's own port sequence (tools/hwprobe/xe10t/sec_opna2.inc o2_adpcmb): after 0x110 = 00, a 0x100 = 01 reset and a 0x110 = 80 flag reset, memory-write mode (0x100 = 60, 0x101 = 02, start = stop = 0000, limit FFFF) takes each of 40 bytes of 0x80 written through 0x108 with BRDY (0x18C bit 3) set after every byte, EOS (bit 2) stays clear through the 31st byte and is set from the 33rd byte on (the stop address, 32 bytes in 8-bit units, reached), the ADB_END status reads EOS and BRDY (st=0C) and the +6 read with 0x08 still selected answers the byte just written (s6=80, docs/probes/XE10T-XE10-OPNA2.TXT `ADB_W i=32 ... st=0C`, `ADB_END st=0C s6=80`), a following 0x110 = 80 flag reset clears EOS, and BRDY stays clear after a flag reset until the next 0x100 write or memory byte: the set-up's reset reads it clear at the first read (`ADB_SETUP ... st1=00 stl=00 reads=1`) and the set-up's writes set it again (`s_set=08`), and after eight resets in a row the last five each read BRDY and EOS clear at the first read (`FR_ADB i=3..7 st1=00 stl=00 reads=1`) while BRDY is back, with nothing written, by the next row 100 us later (`FR_ADB i=4..7 sb=08`).
//
// WHERE THE EXPECTED VALUES COME FROM: the real Xe10's /OPNA2 run,
// docs/probes/XE10T-XE10-OPNA2.TXT, the ADB rows (lines 574-623):
//   * `ADB_SETUP st0=00 s_rst=08 sb=08 st1=00 stl=00 reads=1 pit=15 s_set=08`: BRDY reads
//     set after the 0x100 = 01 reset and after the set-up, and the 0x110 = 80 reset between
//     them clears it at the first read and keeps it clear to the end of the read loop
//     (st1=00 stl=00 reads=1; jt08_adpcm_drvB.v's LOCAL FIX).
//   * `ADB_W i=0 ... st=08` through `i=31 ... st=88`: BRDY set after each byte, EOS clear.
//     Bit 7 (BUSY) comes and goes between bytes on the machine and is not asserted.
//   * `ADB_W i=32 reads=1 pit=11 st=0C` through `i=39 ... st=0C`: EOS set. The stop
//     address in 8-bit units ends at byte 32 (0x101 bit 1, stop 0000: bytes 0-31; ymfm
//     ymfm_adpcm.cpp adpcm_b_channel::write_ram `set_reset_status(STATUS_EOS);` after the
//     write at the stop address; NP2kai sound/adpcmc.c stop `(LOADINTELWORD(ad->reg.stop) +
//     1) << 5`). The row after the 32nd byte (i=31) read EOS still clear on the machine,
//     with BUSY set (`st=88`): the chip's write of that byte was still in flight when the
//     probe saw BRDY, so i=31 is not asserted either way.
//   * `ADB_END st=0C s6=80`: the +6 read after the last byte answers that byte (the probe
//     writes 0x80 every time).
//   * `FR_ADB i=0 sb=0C st1=0C stl=08`: the 0x110 = 80 reset clears EOS (the machine shows
//     it once more at the first read; the core may be faster). The BRDY that the machine
//     then keeps through three resets (FR_ADB i=0..2 time out at 4096 reads) is not
//     asserted (no reference explains it, todo item 38); `FR_ADB i=3..7 sb=08 st1=00
//     stl=00 reads=1` are: by then each reset leaves BRDY and EOS clear at the first read.
//
// ==== DUT ====
// pc9821_opna (the board glue and the vendored YM2608) with the extension open, as the
// probe runs the section (`s_rst=08`: the extended status answers, not FF).

module tb_pc9821_opna_adpcmb_mem;
  localparam integer SYS_CLOCK_HZ = 50_000_000;
  localparam real    CLK_NS       = 1_000_000_000.0 / SYS_CLOCK_HZ;

  reg clk = 0;
  always #(CLK_NS/2.0) clk = ~clk;

  reg        reset = 1;
  reg [15:0] io_addr = 16'h0188;
  reg        io_wr = 0, io_rd = 0;
  reg  [7:0] io_din = 8'h00;
  reg        extend = 1'b1;
  wire [7:0] io_dout;
  wire       io_rd_wait, io_rd_hold, io_wr_wait;
  wire       irq;
  wire signed [19:0] snd_l, snd_r;

  pc9821_opna #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) dut (
    .clk(clk), .reset(reset),
    .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd),
    .io_din(io_din), .io_dout(io_dout), .io_rd_wait(io_rd_wait),
    .io_rd_hold(io_rd_hold), .io_wr_wait(io_wr_wait),
    .extend(extend), .joystick(6'b111111),
    .snd_l(snd_l), .snd_r(snd_r),
    .irq(irq),
    .rhythm_we(1'b0), .rhythm_waddr(12'd0), .rhythm_wdata(16'd0)
  );

  integer errors = 0;
  task automatic fail(input [8*120-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ==== STIMULUS: the probe's port helpers ====
  // One `out`: a one-clk write strobe, as pc9821_iobus presents it.
  task automatic p_out(input [15:0] port, input [7:0] data);
    begin
      @(negedge clk); io_addr = port; io_din = data; io_wr = 1;
      @(negedge clk); io_wr = 0; io_din = 8'h00;
      while (io_wr_wait) @(negedge clk);
      repeat (2) @(negedge clk);
    end
  endtask
  // One `in`: the strobe, held while the glue asks for its wait/hold.
  task automatic p_in(input [15:0] port, output [7:0] data);
    begin
      @(negedge clk); io_addr = port; io_rd = 1;
      @(negedge clk); io_rd = 0;
      while (io_rd_hold) @(negedge clk);
      #1 data = io_dout;
      repeat (2) @(negedge clk);
    end
  endtask
  // o2_wait: poll the base status until bit 7 clears.
  task automatic o2_wait;
    reg [7:0] s;
    begin
      p_in(16'h0188, s);
      while (s[7]) p_in(16'h0188, s);
    end
  endtask
  // o2_putx: BUSY-polled extended select (+4) and data (+6).
  task automatic o2_putx(input [7:0] r, input [7:0] d);
    begin
      o2_wait; p_out(16'h018C, r);
      o2_wait; p_out(16'h018E, d);
    end
  endtask
  // o2_xfr: select 0x10, read the status (sb), write 0x80 (the flag reset), then read the
  // status until bits 3:2 clear or 4096 reads.
  task automatic o2_xfr(output [7:0] sb, output [7:0] st1, output [7:0] stl,
                        output integer reads);
    reg [7:0] s;
    begin
      o2_wait; p_out(16'h018C, 8'h10);
      o2_wait; p_in(16'h018C, sb);
      p_out(16'h018E, 8'h80);
      reads = 0;
      do begin
        p_in(16'h018C, s);
        reads = reads + 1;
        if (reads == 1) st1 = s;
      end while ((s & 8'h0C) && reads < 4096);
      stl = s;
    end
  endtask

  // ==== CHECKS ====
  // The probe's rows in order, each compared with the machine's bytes as it is read.
  reg [7:0] st0, s_rst, sb, st1, stl, s_set, st, s6;
  integer   reads, i, polls;

  initial begin
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (400) @(negedge clk);   // the chip's stretched reset (16 cen)

    // ==== ADB_SETUP ====
    p_in(16'h018C, st0);
    o2_putx(8'h10, 8'h00);         // 0x110 <- 00: no flag masked
    o2_putx(8'h00, 8'h01);         // 0x100 <- 01: reset
    o2_wait;
    p_in(16'h018C, s_rst);
    o2_xfr(sb, st1, stl, reads);
    o2_putx(8'h00, 8'h60);         // memory write (record, external)
    o2_putx(8'h01, 8'h02);         // RAM, 8-bit access
    o2_putx(8'h02, 8'h00);
    o2_putx(8'h03, 8'h00);
    o2_putx(8'h04, 8'h00);
    o2_putx(8'h05, 8'h00);
    o2_putx(8'h0C, 8'hFF);
    o2_putx(8'h0D, 8'hFF);
    o2_wait;
    p_in(16'h018C, s_set);
    $display("  ADB_SETUP st0=%02x s_rst=%02x sb=%02x st1=%02x stl=%02x reads=%0d s_set=%02x",
             st0, s_rst, sb, st1, stl, reads, s_set);
    if (s_rst[3] !== 1'b1) fail("ADB_SETUP: BRDY not set after the 0x100 = 01 reset (machine s_rst=08)");
    if (st1[3:2] !== 2'b00 || stl[3:2] !== 2'b00 || reads != 1)
      fail("ADB_SETUP: the 0x110 = 80 reset did not leave BRDY clear (machine st1=00 stl=00 reads=1)");
    if (s_set[3:2] !== 2'b10) fail("ADB_SETUP: the status after the set-up is not the machine's BRDY alone (s_set=08)");

    // ==== ADB_W: 40 bytes through 0x108, each followed by a BRDY poll ====
    for (i = 0; i < 40; i = i + 1) begin
      o2_wait; p_out(16'h018C, 8'h08);
      o2_wait; p_out(16'h018E, 8'h80);
      polls = 0;
      do begin p_in(16'h018C, st); polls = polls + 1; end
      while (!st[3] && polls < 4096);
      $display("  ADB_W i=%0d reads=%0d st=%02x", i, polls, st);
      if (!st[3]) fail("ADB_W: BRDY did not follow a 0x108 byte (machine 40/40)");
      if (i <= 30 && st[2]) fail("ADB_W: EOS set before the stop address (machine st=08 to i=31)");
      if (i >= 32 && !st[2]) fail("ADB_W: EOS not set after the stop address (machine st=0C from i=32)");
    end

    // ==== ADB_END ====
    p_in(16'h018C, st);
    p_in(16'h018E, s6);
    $display("  ADB_END st=%02x s6=%02x", st, s6);
    if (st[3:2] !== 2'b11) fail("ADB_END: status is not the machine's EOS|BRDY (st=0C)");
    if (s6 !== 8'h80) fail("ADB_END: the +6 read is not the byte just written (machine s6=80)");

    // ==== FR_ADB i=0: the flag reset clears EOS ====
    o2_xfr(sb, st1, stl, reads);
    $display("  FR_ADB i=0 sb=%02x st1=%02x stl=%02x reads=%0d", sb, st1, stl, reads);
    if (sb[2] !== 1'b1) fail("FR_ADB: EOS not set before the reset (machine sb=0C)");
    if (stl[2] !== 1'b0) fail("FR_ADB: the 0x110 = 80 reset did not clear EOS (machine stl=08)");
    // FR_ADB i=1..7: the machine's i=3..7 read BRDY and EOS clear at the first read.
    // Between rows the probe prints its line (far longer than 100 us); the machine's first
    // read of each row then finds BRDY set again (sb=08), also after a row that left it clear.
    for (i = 1; i < 8; i = i + 1) begin
      #100_000;
      o2_xfr(sb, st1, stl, reads);
      if (i >= 4 && sb[3] !== 1'b1)
        fail("FR_ADB: BRDY did not come back between rows with the port idle (machine i=4..7 sb=08)");
      $display("  FR_ADB i=%0d sb=%02x st1=%02x stl=%02x reads=%0d", i, sb, st1, stl, reads);
      if (i >= 3 && (st1[3:2] !== 2'b00 || reads != 1))
        fail("FR_ADB: a flag reset did not leave BRDY and EOS clear (machine i=3..7 st1=00 reads=1)");
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_OPNA_ADPCMB_MEM: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OPNA_ADPCMB_MEM: FAIL (%0d errors)", errors);
  end

  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_OPNA_ADPCMB_MEM: TIMEOUT");
  end

endmodule
