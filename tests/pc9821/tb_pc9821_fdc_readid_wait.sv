`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// A READ ID that finds its header answers only once the ID field has passed the head, as the uPD765A reads it off the spinning medium (MAME src/devices/machine/upd765.cpp read_id_continue, the result only at COMMAND_DONE): back-to-back READ IDs complete one sector period of the track apart - REV / sectors at 360 rpm on the 1 MB interface and at 300 rpm once port 0x04BE selects it, within the Xe10's measured 0.92 of the nominal period (docs/probes/XE10T-XE10-FDC.TXT `c2c_art=5908/5917/9842` on an 8-sector track) and the full period - no answer ever comes within the 160 us an MFM ID field takes to read, the MSR shows CB alone (no RQM, no DIO) while the field is searched, and the seven-byte answer {hd<<2|us, 0, 0, C, H, R, N} still carries the track register and the header's R/N, so a driver that sets its "interrupt expected" bit after the last command byte (Windows 95 HSFLOP.PDR's media check, obj3 0x3015E8 `mov al,0x4a` .. 0x3015FD `or byte [0x100980],0x2`) cannot lose the interrupt to an instant answer.
//
// WHY THIS EXISTS. A debug-UART capture of Windows 95 opening a 720 KB disk on the core shows
// every media-check READ ID answered with its interrupt in the same 10 us as the command's last
// byte. HSFLOP.PDR sends READ ID through 0x1000A3 (which executes `sti` first) and only then
// sets bit 1 of its flag word; its ISR (obj1 0x10010F) finds MSR CB set and that bit clear, so
// it EOIs and leaves. The driver then waits 800 ms (VMM Set_Global_Time_Out 0x320), sends SENSE
// DRIVE STATUS into the standing result phase, reads the READ ID's ST0 (0x00) as ST3, sees no
// RDY and takes the drive for empty - a minute of retries with the system blocked.
//
// EXPECTED VALUES. The chip: READ ID reads "the first ID field it can find" (NEC uPD765A data
// sheet), MAME upd765.cpp read_id_continue (SEARCH_ADDRESS_MARK_HEADER, then COMMAND_DONE) and
// msr_r (PHASE_EXEC: CB, RQM only for a data byte). The machine: twenty back-to-back READ IDs on
// a 1.2 MB track complete 5910 ARTIC ticks (19.2 ms) apart, one sector of the 166.7 ms
// revolution (XE10T-XE10-FDC.TXT). An MFM ID field is at least 10 bytes (A1 A1 A1 FE C H R N
// CRC CRC) at 500 kbit/s = 160 us. The answer bytes: NP2kai fdcsend_success7 (io/fdc.c) with C
// from the track register and R/N from the header (fdd_readid_d88). NP2kai answers at once and
// defers only the interrupt by 512 CPU clocks; the chip and the capture are followed.
//
// The instance runs at SYS_CLOCK_HZ = 1.2 MHz: one revolution is 200,000 (360 rpm) or 240,000
// (300 rpm) cycles, and 160 us is 192 cycles.

// ==== DUT ====

module tb_pc9821_fdc_readid_wait;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  localparam integer HZ      = 1_200_000;
  localparam integer REV_360 = HZ / 6;     // 200,000 cycles: 1/6 s
  localparam integer REV_300 = HZ / 5;     // 240,000 cycles: 1/5 s
  localparam integer ID_MIN  = HZ / 6250;  // 160 us: one MFM ID field at 500 kbit/s

  reg        cs = 0, wr = 0, rd = 0;
  reg  [2:0] addr = 0;
  reg  [7:0] din = 0;
  wire [7:0] dout;
  wire       irq;
  wire       strap_2hd;

  wire       media_req, media_req_hdr, media_adv;
  wire [1:0] media_unit;
  wire [7:0] media_c, media_h, media_r, media_n, media_idx;
  wire       media_dma_drq;
  wire [7:0] media_dma_dout;
  reg        sim_hdrv = 1'b0;
  reg  [7:0] sim_hr = 8'h00;
  reg  [7:0] sim_hs = 8'd8;     // the track's sector count, set per case

  pc9821_fdc #(.SYS_CLOCK_HZ(HZ)) dut (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr),
      .win_2dd(1'b0), .strap_2hd(strap_2hd),
      .wr(wr), .rd(rd), .din(din), .dout(dout), .irq(irq),
      .media_present(4'b0001), .writeprotect(4'b0001),
      .media_chg(4'd0), .frame_tick(1'b0),
      .media_req(media_req), .media_req_hdr(media_req_hdr), .media_unit(media_unit),
      .media_c(media_c), .media_h(media_h), .media_tc(), .media_hd(), .media_mf(), .media_2hd(),
      .media_rpm(), .media_r(media_r), .media_n(media_n),
      .media_idx(media_idx),
      .media_ready(1'b1), .media_rdy(1'b0), .media_hdrv(sim_hdrv),
      .media_err(1'b0), .media_dout(8'h00),
      .media_hr(sim_hr), .media_hn(8'h02), .media_hs(sim_hs),
      .media_adv(media_adv),
      .dma_drq(media_dma_drq), .dma_dack(1'b0), .dma_stb(1'b0), .dma_tc(1'b0),
      .dma_dout(media_dma_dout)
  );

  // The medium: a header request is answered on the next cycle with the idx-th header,
  // R = idx + 1, N = 2, as pc9821_fdd_media answers a raw image (its hdrv level stands until
  // the next request).
  always @(posedge clk)
    if (reset) sim_hdrv <= 1'b0;
    else if (media_req) begin
      sim_hdrv <= media_req_hdr;
      sim_hr   <= media_idx + 8'd1;
    end

// ==== CHECKS ====
  integer fails = 0;
  integer i, n, t;

  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_FDC_READID_WAIT: watchdog timeout (no verdict reached)");
  end

  task automatic wr8(input [2:0] a, input [7:0] d);
    begin
      @(negedge clk); cs = 1; addr = a; wr = 1; rd = 0; din = d;
      @(posedge clk);
      @(negedge clk); cs = 0; wr = 0;
    end
  endtask

  reg [7:0] rd_val;
  task automatic rd8(input [2:0] a);
    begin
      @(negedge clk); cs = 1; addr = a; wr = 0; rd = 1;
      #1 rd_val = dout;
      @(posedge clk);
      @(negedge clk); cs = 0; rd = 0;
    end
  endtask

  task automatic expect8(input [7:0] got, input [7:0] want, input [8*56-1:0] what);
    if (got !== want) begin
      $display("  FAIL: %0s: got %02x, expected %02x", what, got, want);
      fails = fails + 1;
    end
  endtask

  reg [7:0] g_rs [0:7];
  integer   g_rlen;
  task automatic get_result;
    begin
      g_rlen = 0;
      for (i = 0; i < 8; i = i + 1) g_rs[i] = 8'hFF;
      rd8(3'd0);
      while (((rd_val & 8'h40) != 0) && (g_rlen < 8)) begin
        rd8(3'd1);
        g_rs[g_rlen] = rd_val;
        g_rlen = g_rlen + 1;
        rd8(3'd0);
      end
    end
  endtask

  // One READ ID (MFM, unit 0, head 0): t = clocks from the last command byte to the interrupt.
  // While it is pending the MSR is sampled at ID_MIN / 2 (the "guest sets its flag" moment):
  // CB alone, no RQM and no DIO, and no interrupt yet.
  integer msr_ok;
  task automatic readid(input [7:0] want_r, input [8*40-1:0] what);
    begin
      wr8(3'd1, 8'h4A); wr8(3'd1, 8'h00);
      t = 0; msr_ok = 1;
      while (!irq && t < 2 * REV_300) begin
        @(negedge clk); t = t + 1;
        if (t == ID_MIN / 2) begin
          #1;
          cs = 1; addr = 3'd0; rd = 1; #1;
          if ((dout & 8'hD0) !== 8'h10) msr_ok = 0;
          @(posedge clk); @(negedge clk); cs = 0; rd = 0; t = t + 1;
        end
      end
      if (msr_ok == 0) begin
        $display("  FAIL: %0s: the MSR while the ID field is searched is not CB alone (RQM/DIO set, or no CB)", what);
        fails = fails + 1;
      end
      if (t < ID_MIN) begin
        $display("  FAIL: %0s: the answer came %0d clocks after the command, before an ID field could be read (%0d)",
                 what, t, ID_MIN);
        fails = fails + 1;
      end
      get_result;
      if (g_rlen !== 7) begin
        $display("  FAIL: %0s: result length %0d, expected 7", what, g_rlen);
        fails = fails + 1;
      end
      expect8(g_rs[0], 8'h00, {what, ": ST0 = hd<<2|us"});
      expect8(g_rs[1], 8'h00, {what, ": ST1"});
      expect8(g_rs[2], 8'h00, {what, ": ST2"});
      expect8(g_rs[3], 8'h00, {what, ": C = the track register"});
      expect8(g_rs[4], 8'h00, {what, ": H"});
      expect8(g_rs[5], want_r, {what, ": R = the header's"});
      expect8(g_rs[6], 8'h02, {what, ": N = the header's"});
      if (irq) begin
        $display("  FAIL: %0s: the interrupt outlived the result phase", what);
        fails = fails + 1;
      end
    end
  endtask

  // RECALIBRATE unit 0 and drain its interrupt: the header ordinal starts again at 0 (NP2kai
  // FDC_Recalibrate resets fdc.crcn), so the next READ ID answers R = 1.
  task automatic recal;
    begin
      wr8(3'd1, 8'h07); wr8(3'd1, 8'h00);
      t = 0;
      while (!irq && t < 100000) begin @(negedge clk); t = t + 1; end
      wr8(3'd1, 8'h08);
      get_result;
      expect8(g_rs[0], 8'h20, "RECALIBRATE: SENSE INT ST0 = SE|us");
    end
  endtask

  // Back-to-back READ IDs on a track of `spt` sectors at revolution `rev`: each completion
  // after the first is one sector period after the previous completion, within
  // [0.85, 1.05] x rev / spt (the Xe10 reads 0.92 of the nominal period between neighbouring
  // IDs). The first command starts at an arbitrary angle, so only ID_MIN binds it.
  integer per, lo, hi, cyc, last_done, c2c;
  always @(posedge clk) cyc <= reset ? 0 : cyc + 1;
  task automatic run(input integer rev, input integer spt, input [8*40-1:0] what);
    begin
      per = rev / spt;
      lo  = (per * 85) / 100;
      hi  = (per * 105) / 100;
      recal;
      for (n = 0; n < spt + 2; n = n + 1) begin
        readid(8'(((n % spt) + 1)), what);
        c2c = cyc - last_done;
        last_done = cyc;
        if (n != 0 && (c2c < lo || c2c > hi)) begin
          $display("  FAIL: %0s #%0d: %0d clocks between neighbouring answers, outside one sector period [%0d, %0d]",
                   what, n, c2c, lo, hi);
          fails = fails + 1;
        end
      end
    end
  endtask

  initial begin
    reset = 1; repeat (4) @(negedge clk);
    reset = 0; repeat (2) @(negedge clk);
    last_done = 0;
    if (strap_2hd !== 1'b1) begin
      $display("  FAIL: the controller must come up on the 1 MB interface (chgreg = 3)");
      fails = fails + 1;
    end

    // ---- 1.2 MB track: 8 sectors at 360 rpm (the capture's medium) ----
    sim_hs = 8'd8;
    run(REV_360, 8, "360 rpm, 8 sectors");

    // ---- 9 sectors at 360 rpm (a 720 KB disk on the 1 MB interface, HSFLOP mode 0) ----
    sim_hs = 8'd9;
    run(REV_360, 9, "360 rpm, 9 sectors");

    // ---- 18 sectors at 300 rpm: 0x04BE selects it for unit 0 (1.44 MB) ----
    wr8(3'd3, 8'h11);
    sim_hs = 8'd18;
    run(REV_300, 18, "300 rpm, 18 sectors");

    // ==== VERDICT ====
    if (fails != 0) $fatal(1, "TB_PC9821_FDC_READID_WAIT: FAIL (%0d errors)", fails);
    $display("TB_PC9821_FDC_READID_WAIT: PASS");
    $finish;
  end

endmodule
