`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// pc9821_fdc's Phase-1 data path against NP2kai io/fdc.c: with media mounted, READ DATA (0x02/0x06/0x0C and their MF variants) takes its eight parameters, walks R..EOT, and is ended either by the DMA engine's TERMINAL COUNT (which NP2kai forces R=1 into the result for, with C unchanged) or by EOT (which advances C), always answering the seven-byte result {ST0,ST1,ST2,C,H,R,N}; with MT the head flips and the other side of the SAME cylinder is read before C advances; a missing sector answers ST0 IC0 with ST1 ND; a write against this read-only medium answers IC0 with ST1 NW; READ ID reports the crcn-th header of the track with C from the track register and R/N from the header; the MSR carries RQM|DIO|CB with the drive-busy bit and NDM through the transfer and returns to idle at the result drain; and a drive with NO media keeps the probe subset's deferred answer, which is why media_present is part of the contract. The DMA model strobes one byte per DRQ with TC coincident with the final strobe, exactly pc9821_dmac's S_DEV. A non-DMA (ND) READ DATA read by polling MSR delivers exactly the medium's bytes even when each sector's bytes arrive after a fetch delay: RQM is shown only while a byte is there (NP2kai fdc_dataread drops RQM between sectors). While RQM is dropped between a PIO read's bytes the MSR keeps CB beside DIO (0x50, never DIO alone: NP2kai fdc_dataread clears only RQM and NDM).
//
// pc9821_fdc's Phase-1 DATA PATH against NP2kai io/fdc.c, driven through the real ports
// with a media that answers the sector seam and a DMA engine that answers the device
// handshake exactly as pc9821_dmac does (one strobe cycle with this channel's DACK
// asserted, terminal count WITH the block's final strobe).
//
// The no-media answers are NOT touched here: they are the probe subset's, pinned by
// tb_pc9821_fdc and tb_pc9821_fdc_conform, and this model keeps them for a unit with no
// media (which is why media_present is part of the contract). This bench drives
// media_present = 01, so every case below is the reference path.
//
// EACH EXPECTATION AND WHERE IT COMES FROM (NP2kai io/fdc.c unless stated):
//  1. FDC_ReadData (:461-510) takes 8 parameters, dispatches on cmd & 0x1F (so 0x06 and
//     0x46 are the same command), reads R .. EOT and finishes with the seven-byte
//     result {ST0,ST1,ST2,C,H,R,N} (fdcsend_success7 :120-158).
//  2. THE DMA ENGINE'S TERMINAL COUNT ENDS THE COMMAND, and NP2kai forces R = 1 into the
//     result when it does (fdc_dataread :925-932): the result's R byte is 1 and C is what
//     the command asked for, NOT C+1. That is the discriminator between the TC path and
//     the EOT path below (both of which answer R = 1).
//  3. AT EOT WITHOUT TC the walk is FDC_ReadData's FDCEVENT_NEXTDATA arm (:479-506):
//     R wraps to 1, and with MT the head flips and the OTHER SIDE OF THE SAME CYLINDER
//     is read (so a 2-sector track with MT walks (C,H)=(0,0) R=1,2 then (0,1) R=1,2);
//     otherwise C advances and the command ends.
//  4. A MISSING SECTOR is ST0 = us|hd<<2|IC0 with ST1 = ND (readsector :417-427) and
//     the same seven-byte shape.
//  5. A WRITE against this medium is ST0 IC0|NW with ST1 NW, because the medium has no
//     write port at all (FDC_DriveCheck(TRUE), :175-193) -- Phase 1 is read-only.
//  6. READ ID answers the crcn-th sector header on the track with C = the track register,
//     H = the head, R/N from the header (fdd_readid_d88 :494-552), and the interrupt
//     comes with the result.
// ==== DUT ====
// ==== DUT ====

module tb_pc9821_fdc_read;

  reg clk = 0;
  always #5 clk = ~clk;   // 100 MHz, the same clk_sys the fit uses
  reg reset = 1;

  // ==== the device ports ====
  reg        cs = 0, wr = 0, rd = 0;
  reg  [2:0] addr = 0;
  reg  [7:0] din = 0;
  wire [7:0] dout;
  wire       irq;
  wire       strap_2hd;

  // ==== the media seam ====
  reg        media_present = 2'b01;
  wire       media_req, media_req_hdr, media_adv;
  wire [1:0] media_unit;
  wire [7:0] media_c, media_h, media_r, media_n, media_idx;
  wire       media_ready, media_rdy, media_hdrv, media_err;
  wire [7:0] media_dout, media_hr, media_hn, media_hs;

  // ==== the DMA device handshake (pc9821_dmac's channel-2 view) ====
  wire       dma_drq;
  reg        dma_dack = 0, dma_stb = 0, dma_tc = 0;
  wire [7:0] dma_dout;

  pc9821_fdc dut (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr),
      // Module-level: every access below is the 2HD window (0x90-0x94), so
      // win_2dd = 0; the strap output is watched, not driven.
      .win_2dd(1'b0), .strap_2hd(strap_2hd),
      .wr(wr), .rd(rd), .din(din), .dout(dout), .irq(irq),
      .media_present(media_present), .writeprotect(4'b0001),
      // No media-change tag: this bench's mounts are not ready changes (pc9821_fdc's media_chg).
      .media_chg(4'd0), .frame_tick(1'b0),
      .media_req(media_req), .media_req_hdr(media_req_hdr), .media_unit(media_unit),
      .media_c(media_c), .media_h(media_h), .media_tc(), .media_hd(), .media_mf(), .media_2hd(), .media_rpm(), .media_r(media_r), .media_n(media_n),
      .media_idx(media_idx),
      .media_ready(media_ready), .media_rdy(media_rdy), .media_hdrv(media_hdrv),
      .media_err(media_err), .media_dout(media_dout),
      .media_hr(media_hr), .media_hn(media_hn), .media_hs(media_hs),
      .media_adv(media_adv),
      .dma_drq(dma_drq), .dma_dack(dma_dack), .dma_stb(dma_stb), .dma_tc(dma_tc),
      .dma_dout(dma_dout)
  );

  // ==== the media model ====
  // The seam's own shape (pc9821_fdd_media): `ready` is high while no request is being
  // served, `rdy` is a LEVEL over the whole sector, `err`/`hdrv` are levels that stand
  // until the next request, `adv` consumes the byte at the pointer.
  reg        sim_xfer, sim_err, sim_hdrv;
  reg [15:0] sim_ptr;
  reg  [7:0] sim_last_r;
  integer    nrec;
  reg        rc_hdr  [0:15];
  reg  [1:0] rc_unit [0:15];
  reg  [7:0] rc_c    [0:15];
  reg  [7:0] rc_h    [0:15];
  reg  [7:0] rc_r    [0:15];
  reg  [7:0] rc_n    [0:15];

  assign media_ready = !sim_xfer;
  assign media_rdy   = sim_xfer;
  assign media_err   = sim_err;
  assign media_hdrv  = sim_hdrv;
  assign media_dout  = sim_xfer ? (sim_last_r ^ sim_ptr[7:0]) : 8'h00;
  assign media_hr    = media_idx + 8'd1;
  assign media_hn    = 8'd3;
  assign media_hs    = 8'd2;

  reg miss_en = 0;             // answer "sector not found" for a data request
  // T13: the medium's byte arrives rdy_delay clocks after the request (0 = the next clock,
  // every earlier case): a real block fetch is not instant, and a PIO reader must wait it out.
  integer rdy_delay = 0;
  integer rdy_cnt = 0;

  always @(posedge clk) begin
    if (reset) begin
      sim_xfer <= 1'b0; sim_err <= 1'b0; sim_hdrv <= 1'b0; sim_ptr <= 16'd0;
      sim_last_r <= 8'h00; nrec = 0;
    end else begin
      if (media_req) begin
        sim_err  <= 1'b0;
        sim_hdrv <= 1'b0;
        if (nrec < 16) begin
          rc_hdr[nrec]  = media_req_hdr;
          rc_unit[nrec] = media_unit;
          rc_c[nrec]    = media_c;
          rc_h[nrec]    = media_h;
          rc_r[nrec]    = media_r;
          rc_n[nrec]    = media_n;
        end
        nrec = nrec + 1;
        if (media_req_hdr) begin
          sim_hdrv <= 1'b1;
        end else if (miss_en) begin
          sim_err <= 1'b1;
        end else begin
          if (rdy_delay == 0) sim_xfer <= 1'b1;
          else rdy_cnt = rdy_delay;
          sim_ptr    <= 16'd0;
          sim_last_r <= media_r;
        end
      end else if (rdy_cnt != 0) begin
        rdy_cnt = rdy_cnt - 1;
        if (rdy_cnt == 0) sim_xfer <= 1'b1;
      end
      if (sim_xfer && media_adv) begin
        if (sim_ptr == 16'd1023) sim_xfer <= 1'b0;
        sim_ptr <= sim_ptr + 16'd1;
      end
    end
  end

  // ==== the DMA model: one strobe per DRQ, TC coincident with the final one ====
  reg [15:0] dm_left;
  reg        dm_run;
  integer    dm_n;
  reg  [7:0] dm_bytes [0:4095];

  // Two cycles per byte, exactly pc9821_dmac's S_FIRST -> S_DEV: the request cycle arms
  // the strobe, the NEXT cycle is the strobe (dack and dev_stb high together, and the
  // engine latches dev_din at ITS end). Capturing in the arm cycle instead would read the
  // byte one transfer early -- the byte is only the engine's during the strobe.
  reg armed;
  always @(posedge clk) begin
    dma_dack <= 1'b0;
    dma_stb  <= 1'b0;
    dma_tc   <= 1'b0;
    if (reset) begin
      dm_left <= 16'd0; dm_run <= 1'b0; dm_n = 0; armed <= 1'b0;
    end else if (armed) begin
      if (dm_n < 4096) dm_bytes[dm_n] = dma_dout;
      dm_n     = dm_n + 1;
      dm_left <= dm_left - 16'd1;
      if (dm_left == 16'd1) dm_run <= 1'b0;
      armed <= 1'b0;
    end else if (dm_run && dma_drq && (dm_left != 16'd0)) begin
      dma_dack <= 1'b1;
      dma_stb  <= 1'b1;
      dma_tc   <= (dm_left == 16'd1);
      armed    <= 1'b1;
    end
  end

// ==== CHECKS ====
  integer fails = 0;
  integer i, n;
  initial begin
    #1_000_000_000;
    $fatal(1, "TB_PC9821_FDC_READ: watchdog timeout (no verdict reached)");
  end

  // ==== the device-port helpers ====
  task automatic wr8(input [2:0] a, input [7:0] d);
    begin
      @(negedge clk); cs = 1; addr = a; wr = 1; rd = 0; din = d;
      @(posedge clk);
      @(negedge clk); cs = 0; wr = 0;
    end
  endtask

  reg [7:0] rd_val;
  // Sample while rd is asserted: the model's read data is combinational, and the posedge
  // advances the result index (the iobus S_BYTE contract).
  task automatic rd8(input [2:0] a);
    begin
      @(negedge clk); cs = 1; addr = a; wr = 0; rd = 1;
      #1 rd_val = dout;
      @(posedge clk);
      @(negedge clk); cs = 0; rd = 0;
    end
  endtask

  task automatic reset_dut;
    begin
      reset = 1; repeat (4) @(negedge clk);
      reset = 0; repeat (2) @(negedge clk);
      dma_dack = 0; dma_stb = 0; dma_tc = 0;
      miss_en = 0;
    end
  endtask

  task automatic expect8(input [7:0] got, input [7:0] want, input [8*40-1:0] what);
    begin
      if (got !== want) begin
        $display("  FAIL: %0s: got %02x, NP2kai says %02x", what, got, want);
        fails = fails + 1;
      end
    end
  endtask

  task automatic expecti(input integer got, input integer want, input [8*40-1:0] what);
    begin
      if (got !== want) begin
        $display("  FAIL: %0s: got %0d, expected %0d", what, got, want);
        fails = fails + 1;
      end
    end
  endtask

  // The seven-byte result, exactly: ST0, ST1, ST2, C, H, R, N.
  reg [7:0] g_rs [0:6];
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

  // A missing sector ends at the controller's second index pulse, up to two revolutions of the
  // slowest spindle (300 rpm) after the command: 2/5 s of the instance's SYS_CLOCK_HZ (the
  // module default, 50 MHz), plus slack (pc9821_fdc X_NDW; tb_pc9821_fdc_nd_search pins it).
  localparam integer ND_WAIT = 2 * (50_000_000 / 5) + 100_000;
  task automatic wait_irq(input integer maxc);
    begin
      n = 0;
      while (!irq && n < maxc) begin @(negedge clk); n = n + 1; end
      if (!irq) begin
        $display("  FAIL: interrupt never came");
        fails = fails + 1;
      end
    end
  endtask

  // The 9-byte command: opcode then the eight parameter bytes.
  task automatic read_cmd(input [7:0] op, input [7:0] ushd,
                          input [7:0] c, input [7:0] h, input [7:0] r,
                          input [7:0] nn, input [7:0] eot);
    begin
      wr8(3'd1, op);
      wr8(3'd1, ushd); wr8(3'd1, c); wr8(3'd1, h); wr8(3'd1, r);
      wr8(3'd1, nn); wr8(3'd1, eot); wr8(3'd1, 8'h1B); wr8(3'd1, 8'hFF);
    end
  endtask

  function automatic [7:0] pat(input [7:0] r, input integer j);
    pat = r ^ j[7:0];
  endfunction

  task automatic check_sector(input integer base, input [7:0] r);
    begin
      for (i = 0; i < 1024; i = i + 1)
        if (dm_bytes[base + i] !== pat(r, i)) begin
          $display("  FAIL: sector R=%0d byte %0d is %02x, the medium's pattern is %02x",
                   r, i, dm_bytes[base + i], pat(r, i));
          fails = fails + 1;
        end
    end
  endtask

  task automatic check_req(input integer k, input integer hdr, input integer unit,
                           input integer c, input integer h, input integer r, input integer nn,
                           input [8*40-1:0] what);
    begin
      if (rc_hdr[k] !== hdr[0] || rc_unit[k] !== unit[1:0] || rc_c[k] !== c[7:0] ||
          rc_h[k] !== h[7:0] || rc_r[k] !== r[7:0] || rc_n[k] !== nn[7:0]) begin
        $display("  FAIL: %0s: request %0d was hdr=%b unit=%0d C=%02x H=%02x R=%02x N=%02x",
                 what, k, rc_hdr[k], rc_unit[k], rc_c[k], rc_h[k], rc_r[k], rc_n[k]);
        fails = fails + 1;
      end
    end
  endtask

  task automatic arm_dma(input integer bytes);
    begin
      dm_left = bytes[15:0]; dm_n = 0; dm_run = 1;
    end
  endtask

  initial begin
    // ---------------- T1: one sector, TERMINAL COUNT at the exact count -------------
    // NP2kai's TC arm (:925-932) ends the command on the final byte and forces R = 1
    // into the result -- with C UNCHANGED, which is what separates it from the EOT arm.
    reset_dut();
    arm_dma(1024);
    read_cmd(8'h06, 8'h00, 8'h00, 8'h00, 8'h01, 8'h03, 8'h08);
    wait_irq(200000);
    get_result;
    expecti(g_rlen, 7, "T1 result length");
    expect8(g_rs[0], 8'h00, "T1 ST0 (hd<<2|us)");
    expect8(g_rs[1], 8'h00, "T1 ST1");
    expect8(g_rs[2], 8'h00, "T1 ST2");
    expect8(g_rs[3], 8'h00, "T1 C unchanged on the TC path");
    expect8(g_rs[4], 8'h00, "T1 H");
    expect8(g_rs[5], 8'h01, "T1 R forced to 1 by the terminal count");
    expect8(g_rs[6], 8'h03, "T1 N");
    expecti(dm_n, 1024, "T1 bytes moved (N+1)");
    check_sector(0, 8'h01);
    expecti(nrec, 1, "T1 one sector request");
    check_req(0, 0, 0, 8'h00, 8'h00, 8'h01, 8'h03, "T1 request");
    if (irq) begin $display("  FAIL: T1 the interrupt must clear with the result drain"); fails = fails + 1; end

    // ---------------- T2: EOT ends it (no terminal count) ---------------------------
    // The DMA count is larger than the transfer, so the command's own EOT walk finishes
    // it: C advances by one and R wraps to 1 (FDC_ReadData :484-495).
    reset_dut();
    arm_dma(4096);
    read_cmd(8'h06, 8'h00, 8'h00, 8'h00, 8'h01, 8'h03, 8'h01);
    wait_irq(200000);
    get_result;
    expecti(g_rlen, 7, "T2 result length");
    expect8(g_rs[0], 8'h00, "T2 ST0");
    expect8(g_rs[3], 8'h01, "T2 EOT path advances C");
    expect8(g_rs[5], 8'h01, "T2 R wraps to 1 at EOT");
    expect8(g_rs[6], 8'h03, "T2 N");
    expecti(dm_n, 1024, "T2 exactly one sector moved");
    expecti(nrec, 1, "T2 one sector request");

    // ---------------- T3: multi-sector, EOT = 3 -------------------------------------
    reset_dut();
    arm_dma(4096);
    read_cmd(8'h06, 8'h00, 8'h00, 8'h00, 8'h01, 8'h03, 8'h03);
    wait_irq(400000);
    get_result;
    expecti(g_rlen, 7, "T3 result length");
    expect8(g_rs[0], 8'h00, "T3 ST0");
    expect8(g_rs[3], 8'h01, "T3 C advances once at EOT");
    expect8(g_rs[5], 8'h01, "T3 R wraps to 1");
    expect8(g_rs[6], 8'h03, "T3 N");
    expecti(dm_n, 3072, "T3 three sectors moved");
    expecti(nrec, 3, "T3 three sector requests");
    check_req(0, 0, 0, 0, 0, 1, 3, "T3 req0");
    check_req(1, 0, 0, 0, 0, 2, 3, "T3 req1");
    check_req(2, 0, 0, 0, 0, 3, 3, "T3 req2");
    check_sector(0, 8'h01);
    check_sector(1024, 8'h02);
    check_sector(2048, 8'h03);

    // ---------------- T4: multi-TRACK (MT), EOT = 2 ---------------------------------
    // 0x86 is READ DATA with MT set: after side 0's EOT the head flips and the OTHER
    // SIDE of the same cylinder is read (FDC_ReadData :482-490).
    reset_dut();
    arm_dma(8192);
    read_cmd(8'h86, 8'h00, 8'h00, 8'h00, 8'h01, 8'h03, 8'h02);
    wait_irq(600000);
    get_result;
    expecti(g_rlen, 7, "T4 result length");
    expect8(g_rs[0], 8'h00, "T4 ST0 (hd is 0 again after the double flip)");
    expect8(g_rs[3], 8'h01, "T4 C advances once after both sides");
    expect8(g_rs[5], 8'h01, "T4 R");
    expect8(g_rs[6], 8'h03, "T4 N");
    expecti(dm_n, 4096, "T4 four sectors moved (two sides)");
    expecti(nrec, 4, "T4 four sector requests");
    check_req(0, 0, 0, 0, 0, 1, 3, "T4 req0 C0 H0 R1");
    check_req(1, 0, 0, 0, 0, 2, 3, "T4 req1 C0 H0 R2");
    check_req(2, 0, 0, 0, 1, 1, 3, "T4 req2 C0 H1 R1");
    check_req(3, 0, 0, 0, 1, 2, 3, "T4 req3 C0 H1 R2");

    // ---------------- T5: missing sector -> ST0 IC0|ND, ST1 ND ----------------------
    reset_dut();
    miss_en = 1;
    arm_dma(4096);
    read_cmd(8'h06, 8'h00, 8'h00, 8'h00, 8'h01, 8'h03, 8'h08);
    wait_irq(ND_WAIT);
    get_result;
    expecti(g_rlen, 7, "T5 result length");
    expect8(g_rs[0], 8'h40, "T5 ST0 = IC0 (readsector :417-427)");
    expect8(g_rs[1], 8'h04, "T5 ST1 = ND");
    expect8(g_rs[3], 8'h00, "T5 C");
    expect8(g_rs[5], 8'h01, "T5 R");
    expect8(g_rs[6], 8'h03, "T5 N");
    expecti(dm_n, 0, "T5 no byte moves on a failed sector");
    expecti(nrec, 1, "T5 one request");

    // ---------------- T6: READ ID walks the track's headers -------------------------
    reset_dut();
    wr8(3'd1, 8'h0A); wr8(3'd1, 8'h00);
    wait_irq(4000);
    get_result;
    expecti(g_rlen, 7, "T6 result length");
    expect8(g_rs[0], 8'h00, "T6 ST0 (hd<<2|us)");
    expect8(g_rs[1], 8'h00, "T6 ST1");
    expect8(g_rs[3], 8'h00, "T6 C = the track register");
    expect8(g_rs[4], 8'h00, "T6 H = the head");
    expect8(g_rs[5], 8'h01, "T6 R = header 1");
    expect8(g_rs[6], 8'h03, "T6 N = 3");
    expecti(nrec, 1, "T6 one header request");
    if (rc_hdr[0] !== 1'b1)
      begin $display("  FAIL: T6 the request must be a HEADER request"); fails = fails + 1; end
    // The second READ ID takes crcn's next header (fdd_readid_d88 :513-518).
    wr8(3'd1, 8'h0A); wr8(3'd1, 8'h00);
    wait_irq(4000);
    get_result;
    expect8(g_rs[5], 8'h02, "T6b R = header 2");
    expecti(nrec, 2, "T6b two header requests");

    // ---------------- T7: a write against this medium answers NW --------------------
    reset_dut();
    wr8(3'd1, 8'h05);
    wr8(3'd1, 8'h00); wr8(3'd1, 8'h00); wr8(3'd1, 8'h00); wr8(3'd1, 8'h01);
    wr8(3'd1, 8'h03); wr8(3'd1, 8'h08); wr8(3'd1, 8'h1B); wr8(3'd1, 8'hFF);
    wait_irq(4000);
    get_result;
    expecti(g_rlen, 7, "T7 result length");
    expect8(g_rs[0], 8'h40, "T7 ST0 = IC0 (FDC_DriveCheck(TRUE))");
    expect8(g_rs[1], 8'h02, "T7 ST1 = NW (the medium has no write port)");
    expect8(g_rs[5], 8'h01, "T7 R");
    expecti(nrec, 0, "T7 no media request at all");

    // ---------------- T8: the status byte while a transfer runs ---------------------
    // A sector request with the DMA held off: the controller sits in its transfer state
    // and the MSR is RQM|DIO|CB with the drive-busy bit (readsector :450-454).
    reset_dut();
    read_cmd(8'h06, 8'h00, 8'h00, 8'h00, 8'h01, 8'h03, 8'h08);
    repeat (40) @(negedge clk);
    rd8(3'd0);
    expect8(rd_val, 8'hD1, "T8 MSR during the transfer = RQM|DIO|CB|busy0");
    arm_dma(1024);
    wait_irq(200000);
    get_result;
    expecti(g_rlen, 7, "T8 result length");
    rd8(3'd0);
    expect8(rd_val, 8'h80, "T8 MSR back to idle after the drain");

    // ---------------- T9: a unit with NO media keeps the probe subset's answer ------
    // The data path is entered only for a drive that HAS media; unit 1 does not, so its
    // READ DATA is the deferred completion the probe benches pin (no result phase, ST0
    // through SENSE INTERRUPT STATUS).
    reset_dut();
    arm_dma(1024);
    read_cmd(8'h06, 8'h01, 8'h00, 8'h00, 8'h01, 8'h03, 8'h08);
    wait_irq(200000);
    rd8(3'd0);
    expect8(rd_val & 8'hC0, 8'h80, "T9 no result phase for a drive with no media");
    wr8(3'd1, 8'h08);
    get_result;
    expecti(g_rlen, 2, "T9 SENSE INTERRUPT STATUS answers the deferred ST0");
    expect8(g_rs[0], 8'h49, "T9 ST0 = IC0|NR|unit 1");
    expecti(dm_n, 0, "T9 no byte moves without media");

    // ---------------- T10: SEEK with media moves the track register ------------------
    // P2-a/P2-c. NP2kai FDC_Seek (io/fdc.c:773-779) on a READY drive sets treg := NCN,
    // resets R, claims the drive and completes with SE (0x20) - NOT the class an empty
    // drive answers (SE|NR = 0x28, or SE|IC0|NR = 0x68 for a unit whose READY is never
    // asserted; the per-state classes of the plan's W1/W2). SENSE INTERRUPT STATUS then
    // reports PCN = treg
    // (FDC_SenceintStatus :586-620). PRE-CHANGE: SEEK never touched treg and answered 0x68,
    // so a driver that positions the head by SEEK (the standard uPD765 idiom) read the wrong
    // track - READ ID uses treg directly (:494-500). SEEK's NCN is its LAST parameter, so it
    // must be read in the cycle it lands, not from the registered cmds[1].
    reset_dut();
    wr8(3'd1, 8'h0F); wr8(3'd1, 8'h00); wr8(3'd1, 8'h07);   // SEEK unit 0, NCN = 7
    wait_irq(200000);
    wr8(3'd1, 8'h08);                                       // SENSE INTERRUPT STATUS
    get_result;
    expecti(g_rlen, 2, "T10 SIS result length");
    expect8(g_rs[0], 8'h20, "T10 ST0 = SE|us (not the no-media 0x68)");
    expect8(g_rs[1], 8'h07, "T10 SIS PCN = the track register SEEK just set");
    wr8(3'd1, 8'h0A); wr8(3'd1, 8'h00);                     // READ ID, unit 0
    wait_irq(4000);
    get_result;
    expect8(g_rs[3], 8'h07, "T10 READ ID C = the SEEKed track register");
    expecti(nrec, 1, "T10 one header request");
    if (rc_c[0] !== 8'h07) begin
      $display("  FAIL: T10 the header request's track is %02x, expected 07", rc_c[0]);
      fails = fails + 1;
    end

    // ---------------- T11: RECALIBRATE with media zeroes the track register ----------
    // P2-b: NP2kai FDC_Recalibrate (:527-563) on a ready drive sets treg := 0 and completes
    // SE|us. PRE-CHANGE: treg kept its last value and the completion was the empty drive's
    // flattened class (0x68 for every drive).
    reset_dut();
    wr8(3'd1, 8'h0F); wr8(3'd1, 8'h00); wr8(3'd1, 8'h0B);   // SEEK to 11 first
    wait_irq(200000);
    wr8(3'd1, 8'h08); get_result;                            // drain that completion
    wr8(3'd1, 8'h07); wr8(3'd1, 8'h00);                      // RECALIBRATE unit 0
    wait_irq(200000);
    wr8(3'd1, 8'h08); get_result;
    expecti(g_rlen, 2, "T11 SIS result length");
    expect8(g_rs[0], 8'h20, "T11 ST0 = SE|us");
    expect8(g_rs[1], 8'h00, "T11 PCN = 0 after the recalibrate");

    // ---------------- T12: a control-port (DOR) write RESETS the controller ----------
    // P2-d. NP2kai's fdc_o94 (io/fdc.c:996-1032) is not a no-op: a change of bit 4 or a 0->1
    // edge of bit 7 calls fdcstatusreset(), which ABORTS the command in progress and returns
    // the controller to the command phase, drive-busy cleared. The machine's own BIOS writes
    // 0x98 there (BANK7@0x7467). PRE-CHANGE: the write was dropped, so a guest could not
    // reset a wedged controller by the standard DOR-reset idiom.
    reset_dut();
    wr8(3'd1, 8'h0F); wr8(3'd1, 8'h00); wr8(3'd1, 8'h03);   // SEEK unit 0: RECAL_CYCLES in ST_EXEC
    repeat (20) @(negedge clk);                              // still inside its delay
    wr8(3'd2, 8'h98);                                        // 0x94 DOR: bit 7 set -> reset
    repeat (4000) @(negedge clk);                            // well past the delay it would have used
    if (irq) begin $display("  FAIL: T12 the aborted SEEK must not interrupt"); fails = fails + 1; end
    rd8(3'd0);
    expect8(rd_val, 8'h80, "T12 the drive-busy bit is cleared by the reset");
    wr8(3'd1, 8'h08);                                        // SENSE INTERRUPT STATUS
    get_result;
    expecti(g_rlen, 1, "T12 SIS after a reset answers only the empty 0x80");
    expect8(g_rs[0], 8'h80, "T12 the aborted completion never queued");

    // ---------------- T13: a NON-DMA (PIO) READ DATA polls RQM per byte -------------------
    // SPECIFY with ND = 1 (third byte bit 0, NP2kai FDC_Specify `fdc.nd = fdc.cmds[1] & 1`),
    // then READ DATA R = 1..2 read by polling: in the execution phase (NDM set) a byte is
    // read only when MSR shows RQM|DIO. NP2kai's data is synchronous, so RQM|DIO|NDM always
    // means a byte is there, and between sectors it clears RQM (fdc_dataread:
    // `fdc.status &= ~(FDCSTAT_RQM | FDCSTAT_NDM);`). With the medium's byte arriving after a
    // fetch delay, the reader must still collect EXACTLY the 2048 medium bytes - no 0x80 idle
    // byte or stale data byte inserted while a sector is being located.
    begin
      integer got, polls, npoll_bad;
      reg [7:0] m, b;
      wr8(3'd1, 8'h03); wr8(3'd1, 8'hDF); wr8(3'd1, 8'h03);   // SPECIFY, ND = 1
      rdy_delay = 40;
      dm_n = 0;
      read_cmd(8'h06, 8'h00, 8'h00, 8'h00, 8'h01, 8'h03, 8'h02);
      got = 0; polls = 0; npoll_bad = 0;
      begin rd8(3'd0); m = rd_val; end
      while (polls < 200000 && !(((m & 8'hC0) == 8'hC0) && ((m & 8'h20) == 0))) begin
        // RQM dropped while the next byte is fetched: NP2kai's `status &= ~(RQM | NDM)`
        // (io/fdc.c fdc_dataread) clears only those two bits, so a drive that is still reading
        // keeps CB (0x10) alongside DIO (0x40): MSR 0x50, never DIO alone.
        if (((m & 8'h80) == 0) && ((m & 8'h40) != 0) && (m & 8'h10) == 0) begin
          npoll_bad = npoll_bad + 1;
        end
        if (((m & 8'hC0) == 8'hC0) && ((m & 8'h20) != 0)) begin
          begin rd8(3'd1); b = rd_val; end
          if (got < 4096) dm_bytes[got] = b;
          got = got + 1;
        end
        begin rd8(3'd0); m = rd_val; end
        polls = polls + 1;
      end
      expecti(npoll_bad, 0, "T13 MSR with RQM dropped mid-transfer keeps CB beside DIO (0x50)");
      expecti(got, 2048, "T13 a PIO reader polling RQM collects exactly the two sectors' bytes");
      if (got == 2048) begin
        check_sector(0, 8'h01);
        check_sector(1024, 8'h02);
      end
      get_result;
      expecti(g_rlen, 7, "T13 the result phase follows the data");
      rdy_delay = 0;
      wr8(3'd1, 8'h03); wr8(3'd1, 8'hDF); wr8(3'd1, 8'h02);   // SPECIFY, back to DMA
    end

  // ==== VERDICT ====
    if (fails == 0) begin
      $display("TB_PC9821_FDC_READ: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_FDC_READ: FAIL (%0d errors)", fails);
  end

endmodule
