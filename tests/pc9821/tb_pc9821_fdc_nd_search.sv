`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// A READ DATA whose sector is not on the track, and a READ ID that finds no header, end at the controller's SECOND index pulse, as the uPD765A/uPD72065 searches the IDs (MAME src/devices/machine/upd765.cpp index_callback, SCAN_ID: `if(fi.counter == 2)`): from every starting angle of the spindle there is no interrupt for at least one revolution and the IC0/ND answer {0x40, 0x04, 0x00, C, H, R, N} comes with the interrupt by the end of the second - 360 rpm (1/6 s) on the 1 MB interface, 300 rpm (1/5 s) once port 0x04BE selects it for the unit - while the MSR shows the command busy (CB and the drive's bit); so a guest that marks its command pending after the last parameter byte (Star Cruiser's IRQ0-stepped loader, 0060:1011 then `mov [0x100],3`) cannot lose the interrupt to an answer that comes before that store.
//
// WHY THIS EXISTS. The controller answered a missing sector in the cycle the medium said
// "not there" - a few clk_sys after the command's last byte. Star Cruiser's loader sends its
// copy-protection probe (READ DATA C=1 H=0 R=0xF4 N=4) from its IRQ0 handler with interrupts
// enabled and only then stores "result pending" (3) into its state byte; the IRQ11 handler
// clears that byte to 0 first, the late store re-arms it, and the loader polls the busy MSR
// forever behind a black screen (hardware at 90 and 50 MHz, and the userdisk tier).
//
// EXPECTED VALUES. The chip: "If the FDC detects the Index Hole twice without finding the
// right sector (indicated in R), then the FDC sets the ND (No Data) flag" (NEC uPD765A data
// sheet, READ DATA; Intel 8272A identical), modelled by MAME upd765.cpp (counter == 2 ->
// SCAN_ID_FAILED). The spindle: 360 rpm for 1.2 MB media on the 1 MB interface, 300 rpm when
// the 3-mode drive is switched to 1.44 MB through 0x04BE (NP2kai io/fdc.c fdc_o4be
// `fdc.rpm[...]`). The answer bytes: NP2kai readsector's missing-sector class (io/fdc.c
// :417-427, fdcsend_error7 :98-119). NP2kai itself answers at once and only defers the
// interrupt by 512 CPU clocks; the chip is followed (pc9821_fdc X_NDW records the divergence).
//
// The instance runs at SYS_CLOCK_HZ = 1.2 MHz so one revolution is 200,000 (360 rpm) or
// 240,000 (300 rpm) cycles; the module derives both from the parameter, so the bench's
// numbers are the module's real-time periods at that clock.

// ==== DUT ====

module tb_pc9821_fdc_nd_search;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  localparam integer HZ      = 1_200_000;
  localparam integer REV_360 = HZ / 6;     // 200,000 cycles: 1/6 s
  localparam integer REV_300 = HZ / 5;     // 240,000 cycles: 1/5 s

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
  reg        sim_err = 1'b0;

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
      .media_ready(1'b1), .media_rdy(1'b0), .media_hdrv(1'b0),
      .media_err(sim_err), .media_dout(8'h00),
      .media_hr(8'h00), .media_hn(8'h00), .media_hs(8'h00),
      .media_adv(media_adv),
      .dma_drq(media_dma_drq), .dma_dack(1'b0), .dma_stb(1'b0), .dma_tc(1'b0),
      .dma_dout(media_dma_dout)
  );

  // The medium: every request (data or header) is answered "not there", as
  // pc9821_fdd_media does for a raw image's out-of-range R or a mismatched N (its `err`
  // level, standing until the next request).
  always @(posedge clk)
    if (reset) sim_err <= 1'b0;
    else if (media_req) sim_err <= 1'b1;

// ==== CHECKS ====
  integer fails = 0;
  integer i, n, t;

  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_FDC_ND_SEARCH: watchdog timeout (no verdict reached)");
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

  task automatic expect8(input [7:0] got, input [7:0] want, input [8*48-1:0] what);
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

  // One command that finds nothing, started `skew` cycles after the previous one ended, so
  // the search begins at a different angle each time. t = clocks from the last parameter
  // byte to the interrupt; the window is [one revolution, two revolutions].
  task automatic one(input integer readid, input integer rev, input integer skew,
                     input [8*48-1:0] what);
    begin
      repeat (skew) @(negedge clk);
      if (readid != 0) begin
        wr8(3'd1, 8'h4A); wr8(3'd1, 8'h00);                      // READ ID (MFM), unit 0
      end else begin
        wr8(3'd1, 8'h46);                                        // READ DATA (MFM)
        wr8(3'd1, 8'h00); wr8(3'd1, 8'h01); wr8(3'd1, 8'h00);    // us/hd, C=1, H=0
        wr8(3'd1, 8'hF4); wr8(3'd1, 8'h04); wr8(3'd1, 8'h08);    // R=F4, N=4, EOT
        wr8(3'd1, 8'h35); wr8(3'd1, 8'hFF);                      // GPL, DTL
      end
      t = 0;
      while (!irq && t < 3 * rev) begin @(negedge clk); t = t + 1; end
      if (t < rev || t > 2 * rev + 8) begin
        $display("  FAIL: %0s: the answer came %0d clocks after the command, outside [%0d, %0d]",
                 what, t, rev, 2 * rev + 8);
        fails = fails + 1;
      end
      get_result;
      if (g_rlen !== 7) begin
        $display("  FAIL: %0s: result length %0d, expected 7", what, g_rlen);
        fails = fails + 1;
      end
      expect8(g_rs[0], 8'h40, {what, ": ST0 = IC0|us"});
      expect8(g_rs[1], 8'h04, {what, ": ST1 = ND"});
      expect8(g_rs[2], 8'h00, {what, ": ST2"});
      if (readid == 0) begin
        expect8(g_rs[3], 8'h01, {what, ": C"});
        expect8(g_rs[5], 8'hF4, {what, ": R"});
        expect8(g_rs[6], 8'h04, {what, ": N"});
      end
      if (irq) begin
        $display("  FAIL: %0s: the interrupt outlived the result phase", what);
        fails = fails + 1;
      end
    end
  endtask

  // The MSR just after the command: the search is running (CB and drive 0's bit), no interrupt.
  task automatic busy_probe(input integer rev);
    begin
      wr8(3'd1, 8'h46);
      wr8(3'd1, 8'h00); wr8(3'd1, 8'h01); wr8(3'd1, 8'h00);
      wr8(3'd1, 8'hF4); wr8(3'd1, 8'h04); wr8(3'd1, 8'h08);
      wr8(3'd1, 8'h35); wr8(3'd1, 8'hFF);
      repeat (16) @(negedge clk);
      rd8(3'd0);
      if ((rd_val & 8'h11) != 8'h11 || irq) begin
        $display("  FAIL: MSR right after the command is %02x (irq=%0d): CB and the drive bit must be set, no interrupt yet",
                 rd_val, irq);
        fails = fails + 1;
      end
      n = 0;
      while (!irq && n < 3 * rev) begin @(negedge clk); n = n + 1; end
      get_result;
    end
  endtask

  initial begin
    reset = 1; repeat (4) @(negedge clk);
    reset = 0; repeat (2) @(negedge clk);
    if (strap_2hd !== 1'b1) begin
      $display("  FAIL: the controller must come up on the 1 MB interface (chgreg = 3)");
      fails = fails + 1;
    end

    // ---------------- 360 rpm: ten starting angles, READ DATA ----------------
    for (n = 0; n < 10; n = n + 1) one(0, REV_360, 1 + n * (REV_360 / 10), "360 rpm READ DATA");
    // ---------------- READ ID that finds no header -----------------------------
    for (n = 0; n < 3; n = n + 1) one(1, REV_360, 7 + n * (REV_360 / 3), "360 rpm READ ID");
    busy_probe(REV_360);

    // ---------------- 300 rpm: 0x04BE selects it for unit 0 --------------------
    wr8(3'd3, 8'h11);                     // bit 4 = write the rpm bit, unit 0, bit 0 = 300 rpm
    for (n = 0; n < 10; n = n + 1) one(0, REV_300, 3 + n * (REV_300 / 10), "300 rpm READ DATA");

    // ==== VERDICT ====
    if (fails != 0) $fatal(1, "TB_PC9821_FDC_ND_SEARCH: FAIL (%0d errors)", fails);
    $display("TB_PC9821_FDC_ND_SEARCH: PASS");
    $finish;
  end

endmodule
