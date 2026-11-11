`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_FDC_LOG: The floppy-controller log (pc9821_fdc_log, the --dbg-fdc debug instrument) puts out the seven-byte record format tools/decode_dbglog.py reads: an ALIVE record (0x5F, a = 0x5A) at power-up; a 0x50 record for every FDC data-port write (0x92 and 0xCA) and a 0x51 for every data-port read, each with the byte and the controller state; an MSR read (0x90/0xC8) only when its value differs from the previous MSR read, carrying the number of unlogged reads of the previous value (a 40-read poll of one value is one record); an interrupt-line edge as a 0x53 record with the new level, also when it coincides with a port access (queued, logged after the access); control-register writes and reads (0x94, 0xCC, 0xBE, 0x4BE, 0xBF) as 0x54 with the register code and a read flag; DMA writes to 0x09/0x0B/0x11-0x1F odd/0x23/0x29/0x0439 as 0x55 and reads of 0x09/0x0B/0x11 as 0x56, while other ports (0x60, 0x05, 0x21) are not logged; a 10 us time that advances; and, with the UART stalled until the ring fills, a LOST record (0x5E) carrying the exact count of dropped records once it drains.
//
// The expected values are this instrument's own record definitions (its header and
// tools/decode_dbglog.py), not a hardware fact: the log describes what the guest did.
//
// ==== DUT ====
module tb_pc9821_fdc_log;
  reg clk = 0;
  always #10 clk = ~clk;          // 50 MHz: 500 clocks per 10 us tick
  reg rst_n = 1;
  reg io_stb = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_data = 0;
  reg fdc_irq = 0;
  reg [7:0] fdc_state = 8'h00;
  wire [7:0] log_byte;
  wire log_we;
  reg acc_en = 1'b1;
  wire log_accept = log_we && acc_en;

  pc9821_fdc_log #(.LOG_CLK_HZ(50_000_000)) dut (
      .clk(clk), .rst_n(rst_n), .io_stb(io_stb), .io_wr(io_wr), .io_addr(io_addr), .io_data(io_data),
      .fdc_irq(fdc_irq), .fdc_state(fdc_state),
      .log_byte(log_byte), .log_we(log_we), .log_accept(log_accept));

  integer errors = 0;
  reg [7:0] cap [0:65535];
  integer ncap = 0;
  always @(posedge clk) if (log_accept && ncap < 65536) begin cap[ncap] = log_byte; ncap = ncap + 1; end

  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_FDC_LOG: TIMEOUT");
  end

  // ==== CHECKS ====
  task automatic acc(input wr, input [15:0] a, input [7:0] d);
    begin
      @(negedge clk); io_stb = 1; io_wr = wr; io_addr = a; io_data = d;
      @(negedge clk); io_stb = 0;
      repeat (20) @(negedge clk);           // an I/O access is tens of clocks long
    end
  endtask

  // the records in the capture, in order
  reg [7:0] rt [0:4095];
  reg [7:0] ra [0:4095];
  reg [7:0] rb [0:4095];
  reg [23:0] rtm [0:4095];
  integer nrec;
  task automatic parse;
    integer i;
    begin
      nrec = 0; i = 0;
      while (i + 7 <= ncap) begin
        if (cap[i] != 8'hA5) begin
          $display("FAIL: byte %0d is not a record start (%02x)", i, cap[i]); errors = errors + 1; i = ncap;
        end else begin
          rt[nrec] = cap[i+1]; rtm[nrec] = {cap[i+2], cap[i+3], cap[i+4]}; ra[nrec] = cap[i+5]; rb[nrec] = cap[i+6];
          nrec = nrec + 1; i = i + 7;
        end
      end
      if (i != ncap) begin $display("FAIL: %0d byte(s) of a partial record", ncap - i); errors = errors + 1; end
    end
  endtask

  integer k;
  task automatic expect_rec(input integer n, input [7:0] t, input [7:0] a, input [7:0] b, input [8*48-1:0] what);
    begin
      if (n >= nrec || rt[n] !== t || ra[n] !== a || rb[n] !== b) begin
        $display("FAIL: %0s: record %0d = %02x/%02x/%02x, expected %02x/%02x/%02x", what, n,
                 (n < nrec) ? rt[n] : 8'hxx, (n < nrec) ? ra[n] : 8'hxx, (n < nrec) ? rb[n] : 8'hxx, t, a, b);
        errors = errors + 1;
      end
    end
  endtask

  // ==== STIMULUS ====
  integer i, nlost, nl, n0;
  initial begin
    repeat (200) @(negedge clk);
    // the driver's SENSE DRIVE STATUS, as the log sees it
    fdc_state = 8'h00;
    acc(1'b0, 16'h0090, 8'h80);                       // MSR 80: first read -> logged (count 0)
    for (i = 0; i < 39; i = i + 1) acc(1'b0, 16'h0090, 8'h80);   // 39 more: none logged
    acc(1'b1, 16'h0092, 8'h04);                       // command byte
    fdc_state = 8'h08;
    acc(1'b0, 16'h0090, 8'h90);                       // MSR changes -> logged with count 39
    acc(1'b1, 16'h0092, 8'h00);                       // parameter
    fdc_state = 8'h18;
    acc(1'b0, 16'h0090, 8'hD0);
    acc(1'b0, 16'h0092, 8'h38);                       // ST3
    fdc_state = 8'h00;
    // the reset and the interrupt that follows; the edge lands in the same cycle as an access
    acc(1'b1, 16'h0094, 8'h98);
    acc(1'b1, 16'h0094, 8'h18);
    @(negedge clk); io_stb = 1; io_wr = 0; io_addr = 16'h00BE; io_data = 8'hFF; fdc_irq = 1; fdc_state = 8'h80;
    @(negedge clk); io_stb = 0;
    repeat (20) @(negedge clk);
    acc(1'b1, 16'h04BE, 8'h10);
    acc(1'b1, 16'h00CA, 8'h08);                       // the 2DD window's data port
    @(negedge clk); fdc_irq = 0; fdc_state = 8'h00;
    repeat (20) @(negedge clk);
    // DMA channel 2 programming, and ports that are not logged
    acc(1'b1, 16'h0019, 8'h00);
    acc(1'b1, 16'h0017, 8'h46);
    acc(1'b1, 16'h0009, 8'h00);
    acc(1'b1, 16'h0023, 8'h01);
    acc(1'b1, 16'h000B, 8'hFF);
    acc(1'b1, 16'h0015, 8'h02);
    acc(1'b1, 16'h0439, 8'h04);
    acc(1'b1, 16'h0029, 8'h06);
    acc(1'b0, 16'h0011, 8'h04);
    acc(1'b1, 16'h0060, 8'h55);
    acc(1'b1, 16'h0005, 8'h55);
    acc(1'b1, 16'h0021, 8'h55);
    acc(1'b0, 16'h0005, 8'h55);
    acc(1'b1, 16'h00BF, 8'h07);
    repeat (2000) @(negedge clk);
    parse;
    expect_rec(0,  8'h5F, 8'h5A, 8'h00, "ALIVE at power-up");
    expect_rec(1,  8'h52, 8'h80, 8'h00, "the first MSR read");
    expect_rec(2,  8'h50, 8'h04, 8'h00, "SENSE DRIVE STATUS command byte");
    expect_rec(3,  8'h52, 8'h90, 8'd39,  "MSR change after 39 unlogged reads");
    expect_rec(4,  8'h50, 8'h00, 8'h08, "the parameter byte");
    expect_rec(5,  8'h52, 8'hD0, 8'h00, "MSR result phase");
    expect_rec(6,  8'h51, 8'h38, 8'h18, "ST3 read");
    expect_rec(7,  8'h54, 8'h98, 8'h00, "DOR 0x98");
    expect_rec(8,  8'h54, 8'h18, 8'h00, "DOR 0x18");
    expect_rec(9,  8'h54, 8'hFF, 8'h82, "0xBE read (the access first)");
    expect_rec(10, 8'h53, 8'h01, 8'h80, "the coincident IRQ rise, queued after it");
    expect_rec(11, 8'h54, 8'h10, 8'h03, "0x4BE write");
    expect_rec(12, 8'h50, 8'h08, 8'h80, "the 2DD window's data port");
    expect_rec(13, 8'h53, 8'h00, 8'h00, "IRQ fall");
    expect_rec(14, 8'h55, 8'h19, 8'h00, "DMA flip-flop clear");
    expect_rec(15, 8'h55, 8'h17, 8'h46, "DMA mode");
    expect_rec(16, 8'h55, 8'h09, 8'h00, "ch2 address");
    expect_rec(17, 8'h55, 8'h23, 8'h01, "ch2 bank");
    expect_rec(18, 8'h55, 8'h0B, 8'hFF, "ch2 count");
    expect_rec(19, 8'h55, 8'h15, 8'h02, "single mask");
    expect_rec(20, 8'h55, 8'h39, 8'h04, "port 0x0439");
    expect_rec(21, 8'h55, 8'h29, 8'h06, "bank mode");
    expect_rec(22, 8'h56, 8'h11, 8'h04, "DMA status read");
    expect_rec(23, 8'h54, 8'h07, 8'h04, "0xBF write (0x60/0x05/0x21 writes and the 0x05 read not logged)");
    if (nrec != 24) begin $display("FAIL: %0d records, expected 24", nrec); errors = errors + 1; end
    if (!(rtm[23] > rtm[1])) begin $display("FAIL: the 10 us time did not advance (%0d .. %0d)", rtm[1], rtm[23]); errors = errors + 1; end
    // the overrun: the UART stalls, 400 data writes fill the 2 KiB ring (292 records), the rest
    // are counted; the LOST record carries the exact count
    n0 = nrec;
    acc_en = 1'b0;
    for (i = 0; i < 400; i = i + 1) acc(1'b1, 16'h0092, i[7:0]);
    acc_en = 1'b1;
    repeat (20000) @(negedge clk);
    parse;
    nlost = 0; nl = 0;
    for (k = n0; k < nrec; k = k + 1) begin
      if (rt[k] == 8'h5E) begin nlost = nlost + ra[k]; nl = nl + 1; end
    end
    if (nl < 1) begin $display("FAIL: no LOST record after the overrun"); errors = errors + 1; end
    if ((nrec - n0 - nl) + nlost != 400) begin
      $display("FAIL: %0d delivered + %0d lost != the 400 writes", nrec - n0 - nl, nlost); errors = errors + 1;
    end
    $display("fdc_log: %0d records, %0d lost in the overrun", nrec, nlost);
    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_FDC_LOG: %0d check(s) failed", errors);
    $display("TB_PC9821_FDC_LOG: PASS");
    $finish;
  end
endmodule
