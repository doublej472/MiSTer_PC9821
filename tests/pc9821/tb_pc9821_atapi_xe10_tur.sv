`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATAPI_XE10_TUR: the CD-ROM's answer to the real Xe10 probe's own sequence (docs/probes/XE10T-XE10-CD.TXT, section CD, rows PROBE and PACKETS, a CDU76E with a disc in it that nothing had polled since power-up), replayed against pc9821_atapi with a disc mounted and no command issued since the reset: bank 1 selected, device 0 (0xA0), IDENTIFY PACKET DEVICE reaching DRQ with status 0x58 and word 0 bits 15:14 = 10 (`st=58 atapi=1`), then four TEST UNIT READYs, each answered by REQUEST SENSE when it ends in CHECK. ASSERTED, as the machine answers: the first TEST UNIT READY ends in CHECK (status 0x51, no data phase), and the third and fourth end GOOD (status 0x50, ERROR 0x00). KNOWN DIVERGENCES, printed as WAIVED lines and counted, not asserted (NOT copied into the core: the owner reports that this Xe10's CD drive is faulty (2026-11-12), so the capture is not a trusted reference for the drive's error and sense bytes, and the core keeps NP2kai's answer until a known-good drive is captured): the machine's first CHECK carries ERROR 0x64 (key 6 with ABRT) and sense UNIT ATTENTION 06/29/00 (power-on or reset occurred), where the core answers ERROR 0x20 and NOT READY / 0x3A (NP2kai atapicmd.c's first-TUR-after-a-change form); and its second TEST UNIT READY is a second CHECK, ERROR 0x64 and sense 06/28/00 (not-ready-to-ready, medium may have changed), where the core answers GOOD.
//
// WHY THIS BENCH EXISTS. tb_pc9821_atapi pins the first TUR after a mount to NP2kai's NOT
// READY / 0x3A (0x28 in NEC mode), and no bench held the drive to the machine's own answer.
// The capture is a real drive: CDU76E-NE on bank 1's master, taken from a DOS prompt with no
// CD driver loaded, so the BIOS's own probe (IDENTIFY, INQUIRY) had run but nothing had
// issued TEST UNIT READY since power-up - the state this bench reproduces with a disc
// mounted and a reset. The probe (tools/hwprobe/xe10t/sec_storage.inc sec_cd / cd_row /
// cd_sense) issues exactly: 0x432 <- bank, device select, 0xA1 and 256 data words, a
// 0x064E read, then TEST UNIT READY x4 with REQUEST SENSE (allocation 18) after a CHECK.
// The capture's rows, verbatim:
//   X CD PROBE bank=01 dev=A0 st=58 atapi=1 model=CD-ROM_CDU76E-NE...
//   X CD TUR drq_art=0 end_art=122 st=51 err=64 bytes=0 sense=06/29/00
//   X CD TUR drq_art=0 end_art=108 st=51 err=64 bytes=0 sense=06/28/00
//   X CD TUR drq_art=0 end_art=139 st=50 err=00 bytes=0
//   X CD TUR drq_art=0 end_art=103 st=50 err=00 bytes=0
// The model string is the machine's drive, not this core's ("NEC CD-ROM DRIVE:98", which
// tb_pc9821_atapi pins to NP2kai), so it is not compared. READ(10)/READ TOC/PLAY timed out
// in that run and are not used.

module tb_pc9821_atapi_xe10_tur;
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  integer errors = 0;
  integer waivers = 0;
  reg io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] cd_dout;
  wire cd_own, cd_irq;
  // pc9821_system's IDE read mux reduced to the one device: the CD owns every task-file read
  // it answers (bank 1, device 0); nothing else is on the bus here.
  wire [7:0] dout = cd_own ? cd_dout : 8'hFF;

  reg         img_mounted = 0;
  reg  [63:0] img_size = 0;
  wire [31:0] sd_lba;
  wire [5:0]  sd_blk_cnt;
  wire        sd_rd;
  reg         sd_ack = 0, sd_buff_wr = 0;
  reg  [12:0] sd_buff_addr = 0;
  reg  [15:0] sd_buff_dout = 0;
  wire        cdda_wr, cdda_flush;
  wire [31:0] cdda_data;

  // ==== DUT ====
  /* verilator lint_off PINCONNECTEMPTY */
  pc9821_atapi #(.AUDIO_EN(1'b0)) cd (
      .clk(clk), .rst_n(rst_n),
      .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din), .io_dout(cd_dout),
      .io_own(cd_own), .irq(cd_irq), .xfer(),
      .img_mounted(img_mounted), .img_size(img_size),
      .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_ack(sd_ack),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
      .cdda_req(1'b1), .cdda_req4(1'b1), .cdda_played(1'b0),
      .cdda_flush(cdda_flush), .cdda_wr(cdda_wr), .cdda_data(cdda_data),
      .log_byte(), .log_we(), .log_accept(1'b1)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // ==== STIMULUS ====
  // A 20-sector ISO the hps_io host model serves word by word (the medium's bytes are not
  // what this bench is about; the mount's header fetch reads them).
  localparam integer ISO_SECS = 20;
  function automatic [7:0] dbyte(input integer l, input integer i);
    dbyte = 8'((i ^ (i >> 8) * 29) + l * 13 + 1);
  endfunction
  always @(negedge clk) begin : host
    reg [31:0] lba; integer words;
    if (sd_rd && !sd_ack) begin
      lba = sd_lba; words = (sd_blk_cnt + 1) * 256;
      repeat (6) @(negedge clk);
      sd_ack = 1;
      repeat (3) @(negedge clk);
      for (int w = 0; w < words; w++) begin
        longint o; o = longint'(lba) * 512 + w * 2;
        sd_buff_addr = 13'(w);
        sd_buff_dout = {dbyte(int'((o + 1) / 2048), int'((o + 1) % 2048)),
                        dbyte(int'(o / 2048), int'(o % 2048))};
        sd_buff_wr = 1; @(negedge clk); sd_buff_wr = 0; @(negedge clk);
      end
      repeat (2) @(negedge clk);
      sd_ack = 0;
    end
  end

  task automatic fail(input string msg);
    begin
      errors = errors + 1;
      $display("FAIL: %s", msg);
    end
  endtask
  task automatic waive(input string what, input string core, input string machine);
    begin
      waivers = waivers + 1;
      $display("WAIVED   %s: core %s, machine %s (docs/probes/XE10T-XE10-CD.TXT; a known divergence)",
               what, core, machine);
    end
  endtask
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
  task automatic rdw(output [15:0] w);
    reg [7:0] lo, hi;
    begin rd(16'h0640, lo); rd(16'h0641, hi); w = {hi, lo}; end
  endtask
  task automatic wait_notbusy(input string what);
    reg [7:0] s; integer n;
    begin
      n = 0;
      do begin rd(16'h074C, s); n = n + 1; end while (s[7] && n < 20000);
      if (s[7]) $fatal(1, "TB_PC9821_ATAPI_XE10_TUR: FAIL - %s: BSY never cleared", what);
    end
  endtask

  // One PACKET command (0xA0, the 12-byte CDB in six words), its data phases drained into
  // rbuf, then the status read: the shape tb_pc9821_atapi's `packet` drives and the probe's
  // atapi_cmd issues.
  byte rbuf [0:255];
  integer rlen;
  reg [7:0] pk_status, pk_error;
  task automatic packet(input byte c0, c4, input string what);
    reg [7:0] s, bl, bh; reg [15:0] w; integer cnt, phases;
    begin
      byte cdb [0:11];
      cdb = '{c0, 8'h00, 8'h00, 8'h00, c4, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
      rlen = 0;
      wr(16'h064E, 8'hA0);
      rd(16'h074C, s);
      if (s !== 8'h58) fail({what, ": the packet phase did not present DRQ (0x58)"});
      for (int k = 0; k < 6; k++) begin
        wr(16'h0640, cdb[2 * k]); wr(16'h0641, cdb[2 * k + 1]);
      end
      phases = 0;
      forever begin
        wait_notbusy(what);
        rd(16'h074C, s);
        if (!s[3]) break;
        rd(16'h0648, bl); rd(16'h064A, bh);
        cnt = {bh, bl};
        for (int k = 0; k < (cnt + 1) / 2; k++) begin
          rdw(w);
          if (rlen < 254) begin rbuf[rlen] = w[7:0]; rbuf[rlen + 1] = w[15:8]; end
          rlen = rlen + 2;
        end
        rlen = rlen - (cnt & 1);
        phases++;
        if (phases > 8) $fatal(1, "TB_PC9821_ATAPI_XE10_TUR: FAIL - %s: runaway data phases", what);
      end
      rd(16'h0642, pk_error);
      rd(16'h064E, pk_status);
    end
  endtask

  // ==== CHECKS ====
  reg [7:0] st;
  reg [15:0] w0, wv;
  reg [7:0] tur_st [0:3];
  reg [7:0] tur_err [0:3];
  integer tur_bytes [0:3];
  reg [7:0] sk [0:3], asc [0:3], ascq [0:3];
  integer n;

  initial begin
    // Power-up with the disc in the drive: hps_io mounts the slot, then the machine reset
    // (the medium is the slot's and survives it, as pc9821_atapi's declarations state).
    repeat (4) @(negedge clk);
    rst_n = 1;
    img_size = ISO_SECS * 2048;
    @(negedge clk); img_mounted = 1; repeat (3) @(negedge clk); img_mounted = 0;
    repeat (20000) @(negedge clk);   // the header fetch and the lead-out MSF
    rst_n = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (20) @(negedge clk);

    // ---- PROBE: bank 1, device 0, IDENTIFY PACKET DEVICE ----
    wr(16'h0432, 8'h01);
    wr(16'h064C, 8'hA0);
    wait_notbusy("select");
    wr(16'h064E, 8'hA1);
    n = 0;
    do begin rd(16'h074C, st); n++; end while ((st[7] || !st[3]) && !st[0] && n < 20000);
    if (st !== 8'h58) begin
      $display("FAIL: IDENTIFY PACKET DEVICE status %02x at DRQ, the machine's st=58", st);
      errors++;
    end
    rdw(w0);
    for (int k = 1; k < 256; k++) rdw(wv);
    if (w0[15:14] !== 2'b10) fail("IDENTIFY PACKET word 0 bits 15:14 are not 10 (the probe's atapi=1)");
    rd(16'h064E, st);

    // ---- PACKETS: TEST UNIT READY x4, REQUEST SENSE after a CHECK ----
    for (int t = 0; t < 4; t++) begin
      packet(8'h00, 8'h00, "TEST UNIT READY");
      tur_st[t] = pk_status; tur_err[t] = pk_error; tur_bytes[t] = rlen;
      sk[t] = 8'h00; asc[t] = 8'h00; ascq[t] = 8'h00;
      if (pk_status[0]) begin
        packet(8'h03, 8'd18, "REQUEST SENSE");
        sk[t] = rbuf[2] & 8'h0F; asc[t] = rbuf[12]; ascq[t] = rbuf[13];
      end
      $display("NOTE TUR %0d: st=%02x err=%02x bytes=%0d sense=%02x/%02x/%02x", t + 1,
               tur_st[t], tur_err[t], tur_bytes[t], sk[t], asc[t], ascq[t]);
    end

    // TUR 1: CHECK, no data - asserted; its ERROR byte and sense - waived.
    if (tur_st[0] !== 8'h51) fail("TUR 1: not a CHECK (status 0x51) - the machine's st=51");
    if (tur_bytes[0] != 0) fail("TUR 1: a data phase - the machine's bytes=0");
    if (tur_err[0] !== 8'h64 || sk[0] !== 8'h06 || asc[0] !== 8'h29 || ascq[0] !== 8'h00)
      waive("TUR 1 sense", $sformatf("err=%02x sense=%02x/%02x/%02x", tur_err[0], sk[0], asc[0], ascq[0]),
            "err=64 sense=06/29/00 (UNIT ATTENTION, power on or reset occurred)");
    else $display("ok       TUR 1 sense 06/29/00 as the machine");
    // TUR 2: the machine's second UNIT ATTENTION - waived when the core differs.
    if (tur_st[1] !== 8'h51 || tur_err[1] !== 8'h64 || sk[1] !== 8'h06 || asc[1] !== 8'h28 ||
        ascq[1] !== 8'h00)
      waive("TUR 2", $sformatf("st=%02x err=%02x sense=%02x/%02x/%02x", tur_st[1], tur_err[1], sk[1], asc[1], ascq[1]),
            "st=51 err=64 sense=06/28/00 (UNIT ATTENTION, not ready to ready)");
    else $display("ok       TUR 2 06/28/00 as the machine");
    if (tur_bytes[1] != 0) fail("TUR 2: a data phase - the machine's bytes=0");
    // TUR 3 and 4: GOOD - asserted.
    for (int t = 2; t < 4; t++) begin
      if (tur_st[t] !== 8'h50 || tur_err[t] !== 8'h00 || tur_bytes[t] != 0) begin
        $display("FAIL: TUR %0d: st=%02x err=%02x bytes=%0d, the machine's st=50 err=00 bytes=0",
                 t + 1, tur_st[t], tur_err[t], tur_bytes[t]);
        errors++;
      end
    end

    // ==== VERDICT ====
    $display("NOTE TB_PC9821_ATAPI_XE10_TUR: %0d known divergence(s) waived", waivers);
    if (errors == 0) begin
      $display("TB_PC9821_ATAPI_XE10_TUR: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_ATAPI_XE10_TUR: FAIL (%0d errors)", errors);
  end

  initial begin
    #50_000_000;
    $fatal(1, "TB_PC9821_ATAPI_XE10_TUR: TIMEOUT");
  end

endmodule
