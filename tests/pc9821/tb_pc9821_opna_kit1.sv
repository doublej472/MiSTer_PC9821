`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_OPNA_KIT1: the real Xe10's kit-1 OPNA rows hold on the core's 86-board glue, driven with the probes' own port sequences: READMAP, with 0xA460 bit 0 closed every base-bank select 0x00-0x2F and 0xFF read through 0x18A answers the machine's byte (0x00-0x0D 00, 0x0E/0x0F FF, 0x10-0x1F FF, 0x20-0x2F the select except 0x22 and 0x29 FF, 0xFF the chip ID 01; docs/probes/KIT1-XE10-YM29.TXT READMAP), RD29, 0x29 reads FF just before and just after each write of 1F, 03, 02, 01, 00 and 1F (`RD29 v29=.. pre=FF post=FF`), so a read-modify-write of 0x29 starts from FF as on the machine; STATUS3, with Timer B running (0x26 = 00, 0x27 = 2A) and its flag set, 0x110 <- 1F clears the flag in 0x188 and 0x18C at once and holds it clear for 100 ms while the timer keeps overflowing, and 0x110 <- 00 brings it back only at the next overflow (docs/probes/KIT1-XE10-OPNA.TXT `S3 A0 ... 018C=0A`, `B0 ... 018C=00`, `B1 0188=00 018C=00`, `C0 0188=00 018C=08`, `C1 0188=0A 018C=0A`; the 0x188 rows compared without bit 3, a +0 status bit the core does not model, item 155). Kit 2's rows (docs/probes/KIT2-XE10-OPNA4.TXT, XE10T /OPNA4): RMAP_C, with the extension closed every select 0x30-0xFE echoes except 0xB4-0xB7, which read FF; RMAP_O, with it open every select 0x10-0xFE echoes (0x00-0x0D 00, 0x0E/0x0F FF, 0xFF 01); S3A, the STATUS3 rows with Timer A running (NA = 0, 0x27 = 15): 0x110 <- 1F clears Timer A's flag in 0x188 and 0x18C at once and holds it clear for 100 ms, and 0x110 <- 00 brings it back only at the next overflow (`S3A_A0 st188=29 st18C=09`, `B0 st188=88 st18C=80`, `B1 00 00`, `C0 st188=80 st18C=88`, `C1 st188=09 st18C=09`; 0x188 compared without bits 7, 5 and 3, 0x18C without BUSY).
//
// WHERE THE EXPECTED VALUES COME FROM: the real Xe10's kit-1 runs, never this core.
//   * READMAP and RD29: docs/probes/KIT1-XE10-YM29.TXT (YM29 v3, tools/hwprobe/ym29/ym29.s
//     rm_loop/rd_loop), `BASE b=0188 st=00 st2=00 a460=40` (bit 0 clear: the extension
//     closed) and
//     `READMAP b=0188 r00= 00 00 00 00 00 00 00 00 00 00 00 00 00 00 FF FF r10= FF FF FF FF
//      FF FF FF FF FF FF FF FF FF FF FF FF r20= 20 21 FF 23 24 25 26 27 28 FF 2A 2B 2C 2D 2E
//      2F rFF=01`, then `RD29 v29=1F pre=FF post=FF` ... `RD29 v29=00 pre=FF post=FF` and a
//     second `RD29 v29=1F pre=FF post=FF`. The probe's opn_get writes the select to 0x188,
//     polls 0x188 for BUSY and reads 0x18A; opn_put writes the select and then the data.
//     The SSG registers 0x00-0x0D read 00 there because the probe's restore left them so;
//     this bench reads them from reset, where they are 00 too (ssg_reset_byte; the machine's
//     fresh-boot SSG 7 reads 00, docs/probes/KIT1-XE10-OPNA.TXT CHIPID).
//   * STATUS3: docs/probes/KIT1-XE10-OPNA.TXT (tools/hwprobe/opnapro/opnapro.s
//     sec_status3): 0xA460 bit 0 set, 0x110 <- 00, 0x26 <- 00, 0x27 <- 2A, a poll until
//     0x188 bit 1 is set, then the rows, each a BUSY-polled 0x188 read and a 0x18C read:
//       A0 0188=0A 018C=0A   A1 (+100 ms) 0188=0A 018C=0A
//       B0 (0x110 <- 1F) 0188=08 018C=00   B1 (+100 ms) 0188=00 018C=00
//       C0 (0x110 <- 00) 0188=00 018C=08   C1 (+100 ms) 0188=0A 018C=0A
//     0x188 bit 3 (A0 0A, B0 08, C1 0A) is one of the +0 status bits item 155 leaves
//     unmodelled, so 0x188 is compared with bit 3 cleared on both sides; 0x18C is compared
//     whole (bit 3 there is ADPCM-B BRDY, masked by 0x110 bit 3 and back at C0).
//
// ==== DUT ====
// pc9821_opna (the board glue and the vendored YM2608), as tb_pc9821_opna_xe10_rows
// instantiates it.

module tb_pc9821_opna_kit1;
  localparam integer SYS_CLOCK_HZ = 50_000_000;
  localparam real    CLK_NS       = 1_000_000_000.0 / SYS_CLOCK_HZ;
  localparam integer WAIT_100MS   = SYS_CLOCK_HZ / 10;   // s3_wait: 30720 ARTIC ticks

  reg clk = 0;
  always #(CLK_NS/2.0) clk = ~clk;

  reg        reset = 1;
  reg [15:0] io_addr = 16'h0188;
  reg        io_wr = 0, io_rd = 0;
  reg  [7:0] io_din = 8'h00;
  reg        extend = 1'b0;    // the YM29 run's as-found 0xA460 = 40: closed
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

  // ==== STIMULUS: the probes' port helpers ====
  // One `out`: a one-clk write strobe, as pc9821_iobus presents it.
  task automatic p_out(input [15:0] port, input [7:0] data);
    begin
      @(negedge clk); io_addr = port; io_din = data; io_wr = 1;
      @(negedge clk); io_wr = 0; io_din = 8'h00;
      while (io_wr_wait) @(negedge clk);
      repeat (2) @(negedge clk);
    end
  endtask
  // One `in`: the strobe, held while the glue asks for its hold.
  task automatic p_in(input [15:0] port, output [7:0] data);
    begin
      @(negedge clk); io_addr = port; io_rd = 1;
      @(negedge clk); io_rd = 0;
      while (io_rd_hold) @(negedge clk);
      #1 data = io_dout;
      repeat (2) @(negedge clk);
    end
  endtask
  // opn_wait / opna_ready: poll 0x188 until BUSY (bit 7) clears.
  task automatic opn_wait;
    reg [7:0] s;
    begin
      p_in(16'h0188, s);
      while (s[7]) p_in(16'h0188, s);
    end
  endtask
  // ym29.s opn_get: select, BUSY poll, read 0x18A.
  task automatic opn_get(input [7:0] r, output [7:0] d);
    begin
      opn_wait; p_out(16'h0188, r);
      opn_wait; p_in(16'h018A, d);
    end
  endtask
  // ym29.s opn_put: select, then data, each BUSY-polled.
  task automatic opn_put(input [7:0] r, input [7:0] d);
    begin
      opn_wait; p_out(16'h0188, r);
      opn_wait; p_out(16'h018A, d);
    end
  endtask
  // opnapro.s opna_selhi + opna_exdata: the extended select and its data.
  task automatic ext_put(input [7:0] r, input [7:0] d);
    begin
      p_out(16'h018C, r); opn_wait;
      p_out(16'h018E, d); opn_wait;
    end
  endtask

  // ==== CHECKS ====
  // The machine's READMAP row, select 0x00-0x2F (docs/probes/KIT1-XE10-YM29.TXT).
  // Kit 2's RMAP_C adds 0x30-0xFE: the select, except 0xB4-0xB7 FF (KIT2-XE10-OPNA4.TXT:126-142).
  function automatic [7:0] mach_readmap(input [7:0] r);
    if (r <= 8'h0D)                   mach_readmap = 8'h00;
    else if (r <= 8'h1F)              mach_readmap = 8'hFF;   // 0E, 0F and the rhythm bank
    else if (r == 8'h22 || r == 8'h29) mach_readmap = 8'hFF;
    else if (r >= 8'hB4 && r <= 8'hB7) mach_readmap = 8'hFF;
    else                              mach_readmap = r;       // the select
  endfunction
  // Kit 2's RMAP_O, the extension open (KIT2-XE10-OPNA4.TXT:143-159): 0x00-0x0D 00, 0x0E/0x0F
  // FF, every select 0x10-0xFE echoed.
  function automatic [7:0] mach_readmap_open(input [7:0] r);
    if (r <= 8'h0D)      mach_readmap_open = 8'h00;
    else if (r <= 8'h0F) mach_readmap_open = 8'hFF;
    else                 mach_readmap_open = r;
  endfunction

  // sec_opna4.inc o4_s3rd: 0x188 then 0x18C at once, no BUSY poll, so the machine's bytes carry
  // BUSY (bit 7) right after a write, which the core shows only from its queue (item 155):
  // 0x188 is compared without bits 7, 5 and 3 (the +0 status bits item 155 lists), 0x18C
  // without bit 7.
  task automatic s3a_row(input [8*2-1:0] tag, input [7:0] m188, input [7:0] m18c);
    reg [7:0] s0, s1;
    begin
      p_in(16'h0188, s0);
      p_in(16'h018C, s1);
      $display("  S3A %0s 0188=%02x 018C=%02x (machine %02x %02x)", tag, s0, s1, m188, m18c);
      if ((s0 & 8'h57) !== (m188 & 8'h57))
        fail({"S3A ", tag, ": 0x188 (bits 7, 5, 3 aside) is not the machine's"});
      if ((s1 & 8'h7F) !== (m18c & 8'h7F))
        fail({"S3A ", tag, ": 0x18C (BUSY aside) is not the machine's"});
    end
  endtask

  // opnapro.s s3_read: a BUSY-polled 0x188 read, then 0x18C; compared with the row.
  task automatic s3_row(input [8*2-1:0] tag, input [7:0] m188, input [7:0] m18c);
    reg [7:0] s0, s1;
    begin
      p_in(16'h0188, s0);
      while (s0[7]) p_in(16'h0188, s0);
      p_in(16'h018C, s1);
      $display("  S3 %0s 0188=%02x 018C=%02x (machine %02x %02x)", tag, s0, s1, m188, m18c);
      if ((s0 & 8'hF7) !== (m188 & 8'hF7))
        fail({"STATUS3 ", tag, ": 0x188 (bit 3 aside) is not the machine's"});
      if (s1 !== m18c)
        fail({"STATUS3 ", tag, ": 0x18C is not the machine's"});
    end
  endtask

  reg [7:0] v, pre, post;
  reg [7:0] v29 [0:5];
  integer   i, n;

  initial begin
    v29[0] = 8'h1F; v29[1] = 8'h03; v29[2] = 8'h02;
    v29[3] = 8'h01; v29[4] = 8'h00; v29[5] = 8'h1F;
    repeat (20) @(posedge clk);
    reset = 0;
    repeat (400) @(posedge clk);       // the glue's stretched chip reset and SSG sweep

    // ---- READMAP: the extension closed, select only, no write ----
    for (i = 0; i < 8'hFF; i = i + 1) begin
      opn_get(i[7:0], v);
      if (v !== mach_readmap(i[7:0])) begin
        $display("  READMAP r%02x=%02x (machine %02x)", i, v, mach_readmap(i[7:0]));
        fail("READMAP: a 0x18A read is not the machine's byte (extension closed)");
      end
    end
    opn_get(8'hFF, v);
    if (v !== 8'h01) fail("READMAP: rFF is not the machine's chip ID 01");

    // ---- RD29: 0x29 read before and after each write ----
    for (i = 0; i < 6; i = i + 1) begin
      opn_get(8'h29, pre);
      opn_put(8'h29, v29[i]);
      opn_get(8'h29, post);
      $display("  RD29 v29=%02x pre=%02x post=%02x (machine FF FF)", v29[i], pre, post);
      if (pre !== 8'hFF)  fail("RD29: 0x29 before the write is not the machine's FF");
      if (post !== 8'hFF) fail("RD29: 0x29 after the write is not the machine's FF");
    end

    // ---- RMAP_O: the extension open, select only (kit 2) ----
    extend = 1'b1;                     // opna_ext 1
    repeat (4) @(negedge clk);
    for (i = 0; i < 8'hFF; i = i + 1) begin
      opn_get(i[7:0], v);
      if (v !== mach_readmap_open(i[7:0])) begin
        $display("  RMAP_O r%02x=%02x (machine %02x)", i, v, mach_readmap_open(i[7:0]));
        fail("RMAP_O: a 0x18A read is not the machine's byte (extension open)");
      end
    end
    opn_get(8'hFF, v);
    if (v !== 8'h01) fail("RMAP_O: rFF is not the machine's chip ID 01");

    // ---- STATUS3: the 0x110 mask with Timer B's flag held set ----
    ext_put(8'h10, 8'h00);
    opn_put(8'h26, 8'h00);
    opn_put(8'h27, 8'h2A);
    n = 0;
    p_in(16'h0188, v);
    while (!v[1] && n < 2_000_000) begin p_in(16'h0188, v); n = n + 1; end
    if (!v[1]) fail("STATUS3: the Timer B flag never rose (the machine's `flag was observed set: Y`)");
    s3_row("A0", 8'h0A, 8'h0A);
    repeat (WAIT_100MS) @(posedge clk);
    s3_row("A1", 8'h0A, 8'h0A);
    ext_put(8'h10, 8'h1F);
    s3_row("B0", 8'h08, 8'h00);
    repeat (WAIT_100MS) @(posedge clk);
    s3_row("B1", 8'h00, 8'h00);
    ext_put(8'h10, 8'h00);
    s3_row("C0", 8'h00, 8'h08);
    repeat (WAIT_100MS) @(posedge clk);
    s3_row("C1", 8'h0A, 8'h0A);
    opn_put(8'h27, 8'h30);

    // ---- S3A: the same rows with Timer A running (kit 2, sec_opna4.inc o4_s3a) ----
    // 0x110 <- 00, NA = 0 (0x24/0x25 <- 00), 0x27 <- 15, the flag waited for (100 ms bound).
    ext_put(8'h10, 8'h00);
    opn_put(8'h24, 8'h00);
    opn_put(8'h25, 8'h00);
    opn_put(8'h27, 8'h15);
    n = 0;
    p_in(16'h0188, v);
    while (!v[0] && n < 2_000_000) begin p_in(16'h0188, v); n = n + 1; end
    if (!v[0]) fail("S3A: the Timer A flag never rose (the machine's `seen=1`)");
    s3a_row("A0", 8'h29, 8'h09);
    repeat (WAIT_100MS) @(posedge clk);
    s3a_row("A1", 8'h09, 8'h09);
    ext_put(8'h10, 8'h1F);
    s3a_row("B0", 8'h88, 8'h80);
    repeat (WAIT_100MS) @(posedge clk);
    s3a_row("B1", 8'h00, 8'h00);
    ext_put(8'h10, 8'h00);
    s3a_row("C0", 8'h80, 8'h88);
    repeat (WAIT_100MS) @(posedge clk);
    s3a_row("C1", 8'h09, 8'h09);
    opn_put(8'h27, 8'h30);

    // ==== VERDICT ====
    // PASS when every row holds; each failing row is named with the capture value it missed.
    if (errors == 0) begin
      $display("TB_PC9821_OPNA_KIT1: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OPNA_KIT1: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000_000;
    $fatal(1, "TB_PC9821_OPNA_KIT1: TIMEOUT");
  end

endmodule
