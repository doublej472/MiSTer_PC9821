`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The FDC's own diagnostics reach the stall record's storage fields end to end: FST packs {IRQ, DRQ, st[2:0], x_st[2:0]} and reads 0x00 after reset, 0x08 mid-parameter, 0x01 waiting on the media's answer, 0x42 with a sector byte waiting on the DMA engine and 0x98 in the result phase with the interrupt raised; FCM carries the command byte's {MT, opcode}; FRS carries {res0, res1, res2, exec_st0} and reads the missing-sector error7 answer 40040000 (ST0 IC0 with ST1 ND, NP2kai readsector fdc.c:417-427); and FCH names the sector in flight {C, H, R, N} from the command's parameters 1..4, so a capture says where a floppy transfer stopped and why it stopped.
//
// WHY IT EXISTS. The FDC had NO telemetry at all: pc9821_fdc exported no diagnostic
// output, so a floppy transfer that failed left nothing in a serial capture but the
// generic IO/DR/IV port latch. The requirement is that when a floppy access misbehaves
// the bitstream says WHY, so this bench pins the whole hop: the controller's real state
// -> the new dbg taps -> pc9821_watchdog_msg's new FST/FCM/FRS/FCH record fields. The
// state encodings asserted here are the module's own localparams (ST_IDLE..ST_RESULT,
// X_IDLE..X_XFER) read out of the record, so a field that renders the wrong sub-field
// fails here rather than decoding as a device fault months later.
//
// The record indices are read BY INDEX on purpose - FST_DIG0 and friends are held to
// the formatter's ROM by tools/check_telemetry_contract.py, the same coordinate check
// tb_pc9821_io_trace's IO= field carries.

module tb_pc9821_fdc_dbg;

// ==== DUT ====
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // The FDC: cs/addr/wr/rd are the 0x90/0x92/0x94 window, win_2dd = 0 (2HD door).
  reg cs = 0, wr = 0, rd = 0;
  reg [2:0] addr = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  wire strap_2hd;
  wire media_req, media_req_hdr;
  wire [1:0] media_unit;
  wire [7:0] media_c, media_h, media_r, media_n, media_idx;
  reg  media_ready = 1'b1;
  reg  media_rdy = 1'b0;
  reg  media_hdrv = 1'b0;
  reg  media_err = 1'b0;
  wire media_adv;
  wire dma_drq;
  wire [7:0] dma_dout;

  // The four taps this bench exists for.
  wire [7:0]  fdc_dbg_state;
  wire [7:0]  fdc_dbg_cmd;
  wire [31:0] fdc_dbg_result;
  wire [31:0] fdc_dbg_chrn;

  pc9821_fdc fdc (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr),
      .win_2dd(1'b0), .strap_2hd(strap_2hd),
      .wr(wr), .rd(rd), .din(din), .dout(dout), .irq(irq),
      // Unit 0 has media; the media ANSWER levels are this bench's stimulus.
      .media_present(4'b0001), .writeprotect(4'b0001),
      // No media-change tag: this bench's mounts are not ready changes (pc9821_fdc's media_chg).
      .media_chg(4'd0), .frame_tick(1'b0),
      .media_req(media_req), .media_req_hdr(media_req_hdr),
      .media_unit(media_unit),
      .media_c(media_c), .media_h(media_h), .media_tc(), .media_hd(), .media_mf(), .media_2hd(), .media_rpm(), .media_r(media_r), .media_n(media_n),
      .media_idx(media_idx),
      .media_ready(media_ready), .media_rdy(media_rdy), .media_hdrv(media_hdrv),
      .media_err(media_err), .media_dout(8'h5A),
      .media_hr(8'h00), .media_hn(8'h00), .media_hs(8'h01),
      .media_adv(media_adv),
      .dma_drq(dma_drq), .dma_dack(1'b0), .dma_stb(1'b0), .dma_tc(1'b0),
      .dma_dout(dma_dout),
      .dbg_state(fdc_dbg_state), .dbg_cmd(fdc_dbg_cmd),
      .dbg_result(fdc_dbg_result), .dbg_chrn(fdc_dbg_chrn)
  );

  // The watchdog formatter, fed ONLY the FDC taps; every other field is tied to zero
  // (they are other benches' subjects). The record is a snapshot: the bench pulses
  // snap and then reads the bytes, exactly pc9821_dbg_record's report accept.
  reg        msg_snap = 0;
  reg [15:0] msg_idx = 0;
  wire [7:0] msg_ch;

  pc9821_watchdog_msg msg (
      .clk(clk), .snap(msg_snap), .idx(msg_idx),
      .cpu_cs(16'h0), .cpu_eip(32'h0), .io_debug_status(8'h0),
      .triple_fault_reset(1'b0), .hdd_mounted(1'b0), .hdd_capacity(32'h0),
      .gdc_disp(1'b0), .vid_frame_cnt(8'h0), .hdd_req_cnt(8'h0), .hdd_err_cnt(8'h0),
      .hdd_busy(1'b0), .hdd_hps_cycles(32'h0),
      .vid_lit_seen(1'b0), .vid_lit_cnt(8'h0),
      .ata_dbg_state(8'h0), .ata_dbg_cmd(32'h0),
      .ata_dbg_lba(32'h0), .ata_dbg_sec(16'h0),
      .io_dbg_gate(4'h0), .mounted_at_run(1'b0),
      .gdc_dbg_sad(16'h0), .gdc_dbg_pitch(8'h0), .gdc_dbg_col40(1'b0), .gdc_dbg_disp(1'b0),
      .kbd_dbg_events(8'h0), .kbd_dbg_delivered(8'h0), .kbd_dbg_rd_data(8'h0),
      .kbd_dbg_wr_ctrl(8'h0), .kbd_dbg_rts(1'b0), .kbd_dbg_rx_en(1'b0), .kbd_irq(1'b0),
      .kbd_dbg_last_del(8'h0), .kbd_dbg_ctrl0(8'h0), .kbd_dbg_ctrl1(8'h0),
      .irq_dbg_imr(8'h0), .irq_dbg_irr(8'h0), .irq_dbg_isr(8'h0), .inta_din(8'h0),
      .cpu_irq_state(8'h0), .inta_count(8'h0),
      .artic_hi(16'h0), .io_itf_stage(8'h0),
      .last_io_addr(16'h0), .last_io_data(8'h0), .last_io_rd(1'b0), .last_io_wr(1'b0),
      .fdc_dbg_state(fdc_dbg_state), .fdc_dbg_cmd(fdc_dbg_cmd),
      .fdc_dbg_result(fdc_dbg_result), .fdc_dbg_chrn(fdc_dbg_chrn),
      .ch(msg_ch)
  );

  // The record indices of the four fields' FIRST digit, in the 351-byte record. These
  // are coordinates in two files (this bench and the formatter's ROM), so
  // tools/check_telemetry_contract.py holds FST_DIG0 to the ROM's " FST=" anchor.
  localparam [15:0] FST_DIG0 = 16'd287;
  localparam [15:0] FCM_DIG0 = 16'd294;
  localparam [15:0] FRS_DIG0 = 16'd301;
  localparam [15:0] FCH_DIG0 = 16'd314;

  // The bound: a stuck DUT cannot outlast this.
  initial begin
    #500_000_000;
    $fatal(1, "TB_PC9821_FDC_DBG: TIMEOUT (no verdict reached)");
  end

// ==== STIMULUS ====
  task wr8(input [2:0] a, input [7:0] d);
    begin
      @(negedge clk); cs = 1; addr = a; wr = 1; rd = 0; din = d;
      @(negedge clk); cs = 0; wr = 0;
    end
  endtask

  // A READ DATA command's eight parameters (NP2kai's get_hdus/get_chrn):
  // p0 = {hd, us}, p1..p4 = C, H, R, N, p5 = EOT, p6 = GPL, p7 = DTL. CHK-2 writes the
  // command and the first two parameters; params_tail continues THAT command with the
  // remaining six (the FSM counts eight total), and read_data_params starts a fresh one.
  task read_data_params_tail;
    begin
      wr8(3'd1, 8'h00);   // H  = 0x00
      wr8(3'd1, 8'h03);   // R  = 0x03
      wr8(3'd1, 8'h02);   // N  = 0x02  (128 << N = 512-byte sector)
      wr8(3'd1, 8'h03);   // EOT
      wr8(3'd1, 8'h00);   // GPL
      wr8(3'd1, 8'hFF);   // DTL
    end
  endtask

  task read_data_params;
    begin
      wr8(3'd1, 8'h00);   // us = 0, hd = 0
      wr8(3'd1, 8'h12);   // C  = 0x12
      read_data_params_tail;
    end
  endtask

  task snap;
    begin
      @(negedge clk); msg_snap = 1;
      @(posedge clk); #1; msg_snap = 0;
    end
  endtask

  // Read n hex digits starting at dig0 and compare. Fail-fast: the first wrong digit
  // names the field and the byte index, which is the coordinate the gate holds.
  task expect_field(input [15:0] dig0, input integer n, input [31:0] exp,
                    input [8*40-1:0] what);
    integer k;
    reg [7:0] c;
    reg [31:0] got;
    begin
      got = 0;
      for (k = 0; k < n; k = k + 1) begin
        msg_idx = dig0 + k[15:0];
        #1;
        c = msg_ch;
        got = (got << 4) | ((c >= 8'h30 && c <= 8'h39) ? (c - 8'h30)
                            : (c >= 8'h41 && c <= 8'h46) ? (c - 8'h37) : 4'hF);
      end
      if (got !== exp)
        $fatal(1, "TB_PC9821_FDC_DBG: %0s: record bytes %0d..%0d read %08x, want %08x",
               what, dig0, dig0 + n - 1, got, exp);
    end
  endtask

  // The labels sit at fixed indices too; a field that moved without its label would
  // leave the two reading different bytes.
  task expect_lit(input [15:0] i, input [7:0] exp, input [8*40-1:0] what);
    begin
      msg_idx = i; #1;
      if (msg_ch !== exp)
        $fatal(1, "TB_PC9821_FDC_DBG: %0s: record byte %0d is %02x, want %02x",
               what, i, msg_ch, exp);
    end
  endtask

// ==== CHECKS ====
  initial begin
    reset = 1;
    repeat (4) @(negedge clk);
    reset = 0;
    repeat (2) @(negedge clk);

    // CHK-0: the labels are where the contract puts them (the four fields' names).
    expect_lit(16'd282, " ",  "FST label");
    expect_lit(16'd283, "F",  "FST label");
    expect_lit(16'd284, "S",  "FST label");
    expect_lit(16'd285, "T",  "FST label");
    expect_lit(16'd286, "=",  "FST label");
    expect_lit(16'd290, "F",  "FCM label");
    expect_lit(16'd298, "R",  "FRS label");
    expect_lit(16'd310, "F",  "FCH label");
    expect_lit(16'd311, "C",  "FCH label");
    expect_lit(16'd312, "H",  "FCH label");

    // CHK-1: the RESET state. st and x_st are both X_IDLE, no IRQ and no DRQ; the
    // command byte is 0; the result word is res[0]=0x80 (the model's reset status,
    // the empty SENSE INTERRUPT answer) with res[1..2] and exec_st0 zero; and no
    // sector is in flight.
    snap;
    expect_field(FST_DIG0, 2, 32'h00, "reset: {IRQ,DRQ,st,x_st}");
    expect_field(FCM_DIG0, 2, 32'h00, "reset: {MT, opcode}");
    expect_field(FRS_DIG0, 8, 32'h80000000, "reset: {res0,res1,res2,exec_st0}");
    expect_field(FCH_DIG0, 8, 32'h00000000, "reset: {C,H,R,N}");

    // CHK-2: MID-PARAMETER. A READ DATA with MT (0x86: MT=1, opcode 6) and two of its
    // eight parameters in: the command byte is captured whole and the state byte shows
    // ST_PARAM (1) with the data path still X_IDLE (0).
    wr8(3'd1, 8'h86);
    wr8(3'd1, 8'h00);
    wr8(3'd1, 8'h12);
    snap;
    expect_field(FST_DIG0, 2, 32'h08, "mid-parameter: st=ST_PARAM, x_st=X_IDLE");
    expect_field(FCM_DIG0, 2, 32'h86, "mid-parameter: {MT=1, READ DATA}");

    // CHK-3: AWAITING THE MEDIA. The last parameter takes the reference data path
    // (media present): the command FSM drops to ST_IDLE and the data path sits in
    // X_REQ until the media answers. The CHRN word carries the sector the command
    // named, C/H/R/N from parameters 1..4, exactly the values on the media request
    // pins (media_c/media_h/media_r/media_n).
    // read_data_params_tail's six bytes are parameters 3..8 of the command CHK-2 opened.
    read_data_params_tail;
    repeat (3) @(negedge clk);
    snap;
    expect_field(FST_DIG0, 2, 32'h01, "awaiting media: st=ST_IDLE, x_st=X_REQ");
    expect_field(FCM_DIG0, 2, 32'h86, "awaiting media: {MT=1, READ DATA}");
    expect_field(FCH_DIG0, 8, 32'h12000302, "awaiting media: C=12 H=00 R=03 N=02");
    if (media_c !== 8'h12 || media_r !== 8'h03 || media_n !== 8'h02)
      $fatal(1, "TB_PC9821_FDC_DBG: media request pins C=%02x R=%02x N=%02x, want 12/03/02",
             media_c, media_r, media_n);

    // CHK-4: THE DMA-STALL SIGNATURE. The media says the byte is ready and nobody
    // takes it: x_st moves to X_XFER and dma_drq rises, so the state byte reads 0x42
    // - a floppy read that hangs on a DMA engine that never strobes shows EXACTLY
    // this in a capture.
    media_rdy = 1;
    repeat (2) @(negedge clk);
    snap;
    expect_field(FST_DIG0, 2, 32'h42, "byte waiting on DMA: drq=1, x_st=X_XFER");

    // CHK-5: the DOR controller reset (the machine's own recovery path, NP2kai
    // fdcstatusreset) drops both FSMs back to idle: 0x00 again.
    wr8(3'd2, 8'h80);
    media_rdy = 0;
    repeat (2) @(negedge clk);
    snap;
    expect_field(FST_DIG0, 2, 32'h00, "DOR reset: both FSMs idle");

    // CHK-6: THE ERROR RESULT. A fresh READ DATA (MT clear this time), then the media
    // answers media_err (the missing-sector class): the model builds error7
    // {ST0 = us|hd<<2|IC0 = 0x40, ST1 = ND = 0x04, ST2 = 0} (NP2kai readsector
    // :417-427 / fdcsend_error7 :98-119) and raises the interrupt with the result
    // phase. FRS reads 40040000 and FST reads 0x98 = {IRQ=1, DRQ=0, ST_RESULT=3,
    // X_IDLE=0}.
    // The answer comes at the controller's second index pulse (pc9821_fdc X_NDW): up to two
    // revolutions of the 300 rpm spindle, 2/5 s of the module-default 50 MHz SYS_CLOCK_HZ.
    wr8(3'd1, 8'h06);
    read_data_params;
    media_err = 1;
    begin : nd_wait
      integer w;
      for (w = 0; w < 2 * (50_000_000 / 5) + 100_000 && !irq; w = w + 1) @(negedge clk);
    end
    repeat (4) @(negedge clk);
    snap;
    expect_field(FST_DIG0, 2, 32'h98, "error result: IRQ raised, st=ST_RESULT");
    expect_field(FRS_DIG0, 8, 32'h40040000, "error result: {0x40, 0x04, 0x00, exec_st0}");
    expect_field(FCM_DIG0, 2, 32'h06, "error result: {MT=0, READ DATA}");
    expect_field(FCH_DIG0, 8, 32'h12000302, "error result: the sector that failed");
    media_err = 0;

    // ==== VERDICT ====
    $display("TB_PC9821_FDC_DBG: PASS");
    $finish;
  end

endmodule

`default_nettype wire
