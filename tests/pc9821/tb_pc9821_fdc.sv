// TB_PC9821_FDC -- the FDC command opcode is its LOW FIVE BITS.
//
// This bench exists for the reported "Rusty freezes on startup" bug. The BIOS's FDD
// driver issues a READ DATA with MF=1 (opcode 0x46), then calls its FDC interrupt wait
// (BANK7 0x7D0A), which polls DS:0x55E for a bit only the FDC ISR (IVT 0x13, slave
// IRQ11) writes. The model decoded the WHOLE opcode byte, so 0x46 fell to its
// "invalid" arm -- which raises NO interrupt -- and the wait never returned.
module tb_pc9821_fdc;
  // ==== WHAT THIS PROVES ====
// The FDC model dispatches its command on the LOW FIVE BITS of the opcode byte, as the uPD765 and NP2kai both do (FDC_Ope[fdc.cmd & 0x1f]), so READ DATA with MF=1 (0x46) completes exactly like READ DATA with MF=0 (0x06) -- eight parameters, the running state, and an interrupt at the end -- and READ ID with MF=1 (0x4A) completes like 0x0A. An opcode the model does not implement still answers its one-byte 'invalid' result WITH NO INTERRUPT. Decoding the WHOLE opcode byte instead sent 0x46 to that invalid arm, raised no interrupt, and left the BIOS's FDC interrupt wait (BANK7 0x7D0A, polling DS:0x55E for a bit only the FDC ISR writes) spinning forever -- which is the reported Rusty freeze. This bench pins both halves, so a whole-byte decode fails it. It also pins the 0x04BE 1.44M/RPM register against NP2kai io/fdc.c:1117-1134: the write stores reg144 and, with bit 4 set, one RPM bit of the drive reg144[6:5] names, and the read answers rpm[reg144[6:5]] | 0xFE.
//
  // The FDC model dispatches its command on the LOW FIVE BITS of the opcode byte, as the uPD765 and NP2kai both do (FDC_Ope[fdc.cmd & 0x1f]), so READ DATA with MF=1 (0x46) completes exactly like READ DATA with MF=0 (0x06) -- eight parameters, the running state, and an interrupt at the end -- and READ ID with MF=1 (0x4A) completes like 0x0A. An opcode the model does not implement still answers its one-byte 'invalid' result WITH NO INTERRUPT. Decoding the WHOLE opcode byte instead sent 0x46 to that invalid arm, raised no interrupt, and left the BIOS's FDC interrupt wait (BANK7 0x7D0A, polling DS:0x55E for a bit only the FDC ISR writes) spinning forever -- which is the reported Rusty freeze. This bench pins both halves, so a whole-byte decode fails it. It also pins the 0x04BE 1.44M/RPM register against NP2kai io/fdc.c:1117-1134 (review iobus-tram F4): the write stores reg144 and, with bit 4 set, one RPM bit, and the read answers rpm[reg144[6:5]] | 0xFE.

  // ==== DUT ====
  reg clk = 0;
  always #5 clk = ~clk;   // 100 MHz, the same clk_sys the fit uses
  reg reset = 1;
  reg cs = 0, wr = 0, rd = 0;
  reg [1:0] addr = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  wire       strap_2hd;

  pc9821_fdc dut (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr),
      // Module-level: every access below is the 2HD window (0x90-0x94), so
      // win_2dd = 0; the strap output is watched, not driven.
      .win_2dd(1'b0), .strap_2hd(strap_2hd),
      .wr(wr), .rd(rd), .din(din), .dout(dout), .irq(irq),
      .media_present(2'b00), .writeprotect(4'b0000),
      // No media-change tag: this bench's mounts are not ready changes (pc9821_fdc's media_chg).
      .media_chg(4'd0), .frame_tick(1'b0),
      .media_req(), .media_req_hdr(), .media_unit(),
      .media_c(), .media_h(), .media_tc(), .media_hd(), .media_mf(), .media_2hd(), .media_rpm(), .media_r(), .media_n(), .media_idx(),
      .media_ready(1'b1), .media_rdy(1'b0), .media_hdrv(1'b0), .media_err(1'b0),
      .media_dout(8'h00), .media_hr(8'h00), .media_hn(8'h00), .media_hs(8'h00),
      .media_adv(), .dma_drq(), .dma_dack(1'b0), .dma_stb(1'b0), .dma_tc(1'b0),
      .dma_dout()
  );

  integer fails = 0;
  integer i;

  // The bound: a stuck DUT cannot outlast this, and the run block $finishes well inside it.
  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_FDC: watchdog timeout (no verdict reached)");
  end

  // ==== CHECKS ====
  task wr8(input [1:0] a, input [7:0] d);
    begin
      @(negedge clk); cs = 1; addr = a; wr = 1; rd = 0; din = d;
      @(negedge clk); cs = 0; wr = 0;
    end
  endtask

  reg [7:0] rd_val;
  task rd8(input [1:0] a);
    begin
      @(negedge clk); cs = 1; addr = a; wr = 0; rd = 1;
      @(negedge clk); rd_val = dout;  // sampled a full cycle in: the model is combinational
      cs = 0; rd = 0;
    end
  endtask

  task expect8(input [7:0] exp, input [8*80-1:0] what);
    begin
      if (rd_val !== exp) begin
        $display("  FAIL: %0s: read %02x expected %02x", what, rd_val, exp);
        fails = fails + 1;
      end
    end
  endtask

  task expect_irq(input exp);
    begin
      if (irq !== exp) begin
        $display("  FAIL: irq=%b expected %b", irq, exp);
        fails = fails + 1;
      end else begin
        $display("  ok:   irq=%b", irq);
      end
    end
  endtask

  task reset_dut;
    begin
      reset = 1; repeat (4) @(negedge clk);
      reset = 0; repeat (2) @(negedge clk);
    end
  endtask

  initial begin
    // READ DATA, MF=0 (0x06): the baseline the FDD probe already used.
    reset_dut();
    wr8(2'd1, 8'h06);
    for (i = 0; i < 8; i = i + 1) wr8(2'd1, i[7:0]);
    repeat (1200) @(negedge clk);
    $display("0x06 READ DATA MF=0 ->");
    expect_irq(1'b1);

    // READ DATA, MF=1 (0x46): THE FIX. A whole-byte decode made this "invalid".
    reset_dut();
    wr8(2'd1, 8'h46);
    for (i = 0; i < 8; i = i + 1) wr8(2'd1, i[7:0]);
    repeat (1200) @(negedge clk);
    $display("0x46 READ DATA MF=1 ->");
    expect_irq(1'b1);

    // READ ID, MF=1 (0x4A): the same low-five-bit dispatch, one parameter.
    reset_dut();
    wr8(2'd1, 8'h4A);
    wr8(2'd1, 8'h00);
    // A not-ready READ ID interrupts about 29 us after its byte on the machine (pc9821_fdc
    // NR_RID_CYCLES, 25 us = 1250 cycles at the DUT's default 50 MHz).
    repeat (1700) @(negedge clk);
    $display("0x4A READ ID MF=1 ->");
    expect_irq(1'b1);

    // An opcode the model does not implement: the invalid arm, deliberately NO interrupt.
    reset_dut();
    wr8(2'd1, 8'h11);
    repeat (1200) @(negedge clk);
    $display("0x11 (unimplemented) ->");
    expect_irq(1'b0);

    // ---- 0x04BE: the 1.44M/RPM register (NP2kai io/fdc.c:1117-1134) ----------
    // The write stores the whole byte in reg144 and - only when its bit 4 is set -
    // bit 0 to the RPM of the drive reg144[6:5] names; the read answers
    // rpm[reg144[6:5]] | 0xFE.
    reset_dut();
    rd8(2'd3);
    expect8(8'hFE, "0x04BE power-up: rpm[0] | 0xFE");
    wr8(2'd3, 8'h51);        // bit 4 set: rpm[drive 2] = 1, and reg144 selects drive 2
    rd8(2'd3);
    expect8(8'hFF, "0x04BE drive 2's RPM bit reads back");
    wr8(2'd3, 8'h00);        // reg144 selects drive 0; bit 4 clear stores NO rpm
    rd8(2'd3);
    expect8(8'hFE, "0x04BE drive 0's RPM is still clear");
    wr8(2'd3, 8'h21);        // drive 1 select, bit 1 set but bit 4 CLEAR: no RPM store
    rd8(2'd3);
    expect8(8'hFE, "0x04BE a bit-4-clear write must not move the RPM bits");

  // ==== VERDICT ====
    if (fails != 0) begin
      $fatal(1, "TB_PC9821_FDC: FAIL (%0d)", fails);
    end
    $display("TB_PC9821_FDC: PASS");
    $finish;
  end
endmodule
