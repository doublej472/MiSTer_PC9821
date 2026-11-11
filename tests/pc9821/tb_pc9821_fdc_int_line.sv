`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_FDC_INT_LINE: the floppy controller's interrupt line is the uPD765A's INT flag, not the level of its status queue: every command or result byte the guest moves through the data port lowers it and a reset written to the 0x94 DOR lowers it, while the statuses already queued stay for SENSE INTERRUPT STATUS (one per command, down to the one-byte 0x80); each later completion and each later ready change raises it again, so a status the guest left undrained never swallows the next interrupt - the Windows 95 floppy driver's reset (SENSE DRIVE STATUS, DOR 0x98, DOR 0x18, then a sleep on the interrupt) still gets its drive-poll interrupt as a rising edge, a WRITE DATA refused on a protected medium and a RECALIBRATE still interrupt; a ready change that arrives while a command is being written, executed or read back is presented when the controller is idle in the command phase again, never inside the command, and one that coincides with a data-port read at idle is not lost. FAIL-FIRST: the base controller drove the line from the queue (any pending status held it high), so after an undrained ready change the reset's poll and the refused write raised no edge (the hang after a direct disk swap), a SENSE INTERRUPT STATUS left the line high while another drive's status was queued, and a change raised the line in the middle of a command.
//
// THE EXPECTED VALUES:
//   MAME src/devices/machine/upd765.cpp, the INT flag `irq`:
//     fifo_w (every data-port write, command and parameter bytes alike): `irq = false; check_irq();`
//     fifo_r (every data-port read, result bytes alike):                  `irq = false; check_irq();`
//     soft_reset (the RESET pin; pc9801.cpp `m_fdc_2hd->reset_w(BIT(data, 7));`): `irq = false;`
//       (MAME also forgets the queued statuses there; NP2kai fdcstatusreset keeps int_stat, and
//       the core keeps NP2kai's - L5 pins only the line);
//     command_end (a completion): `irq = true;`; run_drive_ready_polling: `irq = true;` for a
//       changed drive, and the poll returns at once `if(main_phase != PHASE_CMD || ... ||
//       command_pos)`, so a ready change is presented only with the controller idle in the
//       command phase;
//     SENSE INTERRUPT STATUS: "SIS drops the irq always, but also returns the first full st0 it
//       finds" (the comment above its case), one st0 per command.
//   NP2kai io/fdc.c: each fdc_interrupt() is a fresh PIC request (`pic_setirq(0x0b)`, which sets
//     the IRR bit every call, io/pic.c pic_setirq), so no queued status can absorb a later one.
//     Its diskdrv raises a media change at once, even inside a command; the datasheet's polling,
//     which MAME models, is followed for WHEN the change is presented (as for the reset poll).
//   The ST0 values: an eject/insert is AI|NR|u = 0xC8|u and a ready drive AI|u = 0xC0|u
//     (NP2kai fdd/diskdrv.c diskdrv_setfddex `fdc.stat[drv] = FDCRLT_AI | FDCRLT_NR | drv;`, the
//     uPD765A's drive poll); a WRITE DATA on a protected medium answers ST0 IC0|us = 0x40|u with
//     ST1 NW = 0x02 (NP2kai FDC_DriveCheck(TRUE), `FDCRLT_IC0 | FDCRLT_NW`); SENSE DRIVE STATUS on
//     ready, protected drive 0 at track 0 reads WP|RDY|TS|T0 = 0x78 (FDC_SenseDeviceStatus).
// The DUT runs at its default SYS_CLOCK_HZ = 50 MHz, so the 1.024 ms poll is 51200 cycles.
//
// ==== DUT ====
module tb_pc9821_fdc_int_line;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;
  reg cs = 0, wr = 0, rd = 0;
  reg [2:0] addr = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  reg        tick = 1'b0;
  reg  [1:0] present = 2'b01;      // drive 0 holds a disk, drive 1 is empty
  reg  [1:0] chg = 2'b00;          // pc9821_fdd_media's change tag, one toggle per mount event
  reg  [3:0] wprot = 4'b0001;      // drive 0's disk is write-protected

  pc9821_fdc dut (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr),
      .win_2dd(1'b0), .strap_2hd(),
      .wr(wr), .rd(rd), .din(din), .dout(dout), .irq(irq),
      .media_present({2'b00, present}), .writeprotect(wprot),
      .media_chg({2'b00, chg}), .frame_tick(tick),
      .media_req(), .media_req_hdr(), .media_unit(),
      .media_c(), .media_h(), .media_tc(), .media_hd(), .media_mf(), .media_2hd(), .media_rpm(), .media_r(), .media_n(), .media_idx(),
      .media_ready(1'b1), .media_rdy(1'b0), .media_hdrv(1'b0), .media_err(1'b0),
      .media_dout(8'h00), .media_hr(8'h00), .media_hn(8'h00), .media_hs(8'h00),
      .media_adv(), .dma_drq(), .dma_dack(1'b0), .dma_stb(1'b0), .dma_tc(1'b0),
      .dma_dout(), .res_done(),
      .dbg_state(), .dbg_cmd(), .dbg_result(), .dbg_chrn()
  );

  integer fails = 0;
  integer i, n, t;

  localparam integer POLL     = 51200;    // 1.024 ms at 50 MHz
  localparam integer EARLIEST = 5000;     // MAME's first poll, 100 us after the release

  // The rising edges of the line: what an edge-triggered 8259 (the PC-98's slave, IR3) sees.
  integer edges = 0;
  reg     irq_q = 1'b0;
  always @(posedge clk) begin
    irq_q <= irq;
    if (irq && !irq_q) edges <= edges + 1;
  end

  initial begin
    #30_000_000;
    $fatal(1, "TB_PC9821_FDC_INT_LINE: watchdog timeout (no verdict reached)");
  end

  // ==== CHECKS ====
  task automatic wr8(input [2:0] a, input [7:0] d);
    begin
      @(negedge clk); cs = 1; addr = a; wr = 1; rd = 0; din = d;
      @(negedge clk); cs = 0; wr = 0;
    end
  endtask

  reg [7:0] rd_val;
  task automatic rd8(input [2:0] a);
    begin
      @(negedge clk); cs = 1; addr = a; wr = 0; rd = 1;
      #1 rd_val = dout;
      @(negedge clk); cs = 0; rd = 0;
    end
  endtask

  task automatic check8(input [7:0] got, input [7:0] want, input [8*80-1:0] what);
    begin
      if (got !== want) begin
        $display("  FAIL: %0s: got %02x, expected %02x", what, got, want);
        fails = fails + 1;
      end
    end
  endtask

  task automatic check_irq(input want, input [8*80-1:0] what);
    begin
      if (irq !== want) begin
        $display("  FAIL: %0s: irq=%b, expected %b", what, irq, want);
        fails = fails + 1;
      end
    end
  endtask

  task automatic check_edges(input integer want, input [8*80-1:0] what);
    begin
      if (edges != want) begin
        $display("  FAIL: %0s: %0d rising edges, expected %0d", what, edges, want);
        fails = fails + 1;
      end
    end
  endtask

  reg [7:0] rs [0:7];
  integer   rlen;
  task automatic get_result;
    begin
      rlen = 0;
      for (i = 0; i < 8; i = i + 1) rs[i] = 8'hFF;
      rd8(3'd0);
      while (((rd_val & 8'h40) != 0) && (rlen < 8)) begin
        rd8(3'd1);
        rs[rlen] = rd_val;
        rlen = rlen + 1;
        rd8(3'd0);
      end
    end
  endtask

  task automatic sense_is(input [7:0] st0, input [8*64-1:0] what);
    begin
      wr8(3'd1, 8'h08);
      get_result;
      if (rlen !== ((st0 == 8'h80) ? 1 : 2)) begin
        $display("  FAIL: %0s: SENSE INT length %0d", what, rlen); fails = fails + 1;
      end
      check8(rs[0], st0, {what, ": SENSE INT ST0"});
    end
  endtask

  task automatic frames(input integer k);
    begin
      for (n = 0; n < k; n = n + 1) begin
        @(negedge clk); tick = 1; @(negedge clk); tick = 0;
        repeat (3) @(negedge clk);
      end
    end
  endtask

  task automatic time_irq(input integer lim);
    begin
      t = 0;
      while (!irq && (t <= lim)) begin @(negedge clk); t = t + 1; end
    end
  endtask

  // One mount event of drive u (pc9821_fdd_media toggles its tag once per mount edge).
  task automatic mount_event(input integer u);
    begin
      @(negedge clk); chg[u] = ~chg[u];
      repeat (3) @(negedge clk);
    end
  endtask

  // ==== STIMULUS ====
  initial begin
    repeat (4) @(negedge clk);
    reset = 0; repeat (4) @(negedge clk);

    // L0: the plain cases are unchanged. A ready change at idle raises the line at once; the
    // drain lowers it.
    mount_event(1);
    check_irq(1'b1, "L0 an eject of the empty drive 1 at idle interrupts at once");
    sense_is(8'hC9, "L0 AI|NR|1");
    sense_is(8'h80, "L0 then nothing");
    check_irq(1'b0, "L0 drained");

    // L1: THE HANG. A swap on drive 0 (C8, then 20 frames later its AI: 0xBE bit 2 is clear)
    // whose status the driver's ISR left undrained (it entered with MSR CB set and left).
    mount_event(0);
    frames(21);
    check_irq(1'b1, "L1 the swapped drive's status stands undrained");
    // The driver's reset (HSFLOP 0x30079F): SENSE DRIVE STATUS reads RDY, DOR 0x98, ten 0x5F
    // waits, DOR 0x18, then it sleeps until the interrupt.
    wr8(3'd1, 8'h04);
    check_irq(1'b0, "L1 the SENSE DRIVE STATUS command byte lowers INT (MAME fifo_w)");
    wr8(3'd1, 8'h00);
    get_result;
    check8(rs[0], 8'h78, "L1 SENSE DRIVE STATUS reads WP|RDY|TS|T0");
    check_irq(1'b0, "L1 INT stays low through the result");
    wr8(3'd2, 8'h98);
    repeat (10) @(negedge clk);
    wr8(3'd2, 8'h18);
    edges = 0;
    time_irq(2 * POLL);
    if (t > 2 * POLL) begin
      $display("  FAIL: L1 no interrupt within two polls of the release"); fails = fails + 1;
    end else if (t < EARLIEST) begin
      $display("  FAIL: L1 the line was high %0d cycles after the release, before any poll", t);
      fails = fails + 1;
    end
    repeat (2) @(negedge clk);
    check_edges(1, "L1 the reset's poll is a rising edge the driver is woken by");
    sense_is(8'hC0, "L1 the poll's AI|0");
    sense_is(8'h80, "L1 then nothing");
    check_irq(1'b0, "L1 drained");

    // L2: a data-path result after a stranded status. Drive 1 is ejected (C9), undrained; a
    // WRITE DATA on drive 0's protected disk is refused with its own interrupt.
    mount_event(1);
    check_irq(1'b1, "L2 drive 1's change stands undrained");
    edges = 0;
    wr8(3'd1, 8'h45);                                 // WRITE DATA, MFM
    check_irq(1'b0, "L2 the command byte lowers INT");
    wr8(3'd1, 8'h00); wr8(3'd1, 8'h00); wr8(3'd1, 8'h00); wr8(3'd1, 8'h01);
    wr8(3'd1, 8'h03); wr8(3'd1, 8'h08); wr8(3'd1, 8'h1B);
    check_irq(1'b0, "L2 INT stays low through the parameters");
    wr8(3'd1, 8'hFF);                                 // DTL: the last parameter
    repeat (3) @(negedge clk);
    check_irq(1'b1, "L2 the refused write interrupts");
    check_edges(1, "L2 ... as a rising edge");
    get_result;
    check8(rs[0], 8'h40, "L2 ST0 IC0|0");
    check8(rs[1], 8'h02, "L2 ST1 NW");
    check_irq(1'b0, "L2 the result read lowers INT (MAME fifo_r), the C9 still queued");
    sense_is(8'hC9, "L2 drive 1's status is still there");
    sense_is(8'h80, "L2 then nothing");

    // L3: a ready change inside a command is presented when the command is over.
    edges = 0;
    wr8(3'd1, 8'h03);                                 // SPECIFY, first byte
    mount_event(1);
    repeat (20) @(negedge clk);
    check_irq(1'b0, "L3 no INT while the command is being written");
    wr8(3'd1, 8'hC1);
    check_irq(1'b0, "L3 ... nor after its second byte");
    wr8(3'd1, 8'h46);
    repeat (3) @(negedge clk);
    check_irq(1'b1, "L3 the change is presented once the command is over");
    check_edges(1, "L3 one edge");
    sense_is(8'hC9, "L3 AI|NR|1");
    sense_is(8'h80, "L3 then nothing");
    // ... and inside a result phase: SENSE DRIVE STATUS answered but not yet read.
    edges = 0;
    wr8(3'd1, 8'h04); wr8(3'd1, 8'h00);
    mount_event(1);
    repeat (20) @(negedge clk);
    check_irq(1'b0, "L3 no INT while a result is waiting to be read");
    get_result;
    check8(rs[0], 8'h78, "L3 the result read is drive 0's ST3");
    repeat (3) @(negedge clk);
    check_irq(1'b1, "L3 the change is presented after the result");
    check_edges(1, "L3 one edge");
    sense_is(8'hC9, "L3 AI|NR|1 again");
    sense_is(8'h80, "L3 then nothing");

    // L4: SENSE INTERRUPT STATUS drops INT whatever else is queued.
    @(negedge clk); chg = ~chg;                      // both drives in one cycle
    repeat (3) @(negedge clk);
    check_irq(1'b1, "L4 two changes raise INT");
    wr8(3'd1, 8'h08);
    check_irq(1'b0, "L4 the SENSE INT byte drops INT although drive 1 is still queued");
    get_result;
    check8(rs[0], 8'hC8, "L4 drive 0 first");
    check_irq(1'b0, "L4 INT stays low");
    sense_is(8'hC9, "L4 drive 1 next");
    sense_is(8'h80, "L4 then nothing");

    // L5: a reset written to the DOR drops INT; the queued status survives (NP2kai).
    mount_event(1);
    check_irq(1'b1, "L5 a change raises INT");
    wr8(3'd2, 8'h90);
    check_irq(1'b0, "L5 the reset drops INT");
    wr8(3'd2, 8'h10);
    repeat (3 * POLL) @(negedge clk);
    check_irq(1'b0, "L5 nothing raises it again (no motor bit, no poll)");
    sense_is(8'hC9, "L5 the status is still answered");
    sense_is(8'h80, "L5 then nothing");

    // L6: coincidences (R4). A change in the same cycle as a data-port read at idle is not
    // lost; a change in the same cycle as a SENSE INT command byte is presented after it.
    edges = 0;
    @(negedge clk); cs = 1; addr = 3'd1; rd = 1; chg[1] = ~chg[1];
    @(negedge clk); cs = 0; rd = 0;
    repeat (3) @(negedge clk);
    check_irq(1'b1, "L6 a change with a data-port read in the same cycle still interrupts");
    check_edges(1, "L6 one edge");
    sense_is(8'hC9, "L6 AI|NR|1");
    sense_is(8'h80, "L6 then nothing");
    edges = 0;
    @(negedge clk); cs = 1; addr = 3'd1; wr = 1; din = 8'h08; chg[1] = ~chg[1];
    @(negedge clk); cs = 0; wr = 0;
    check_irq(1'b0, "L6 a change in the SENSE INT byte's cycle waits for the command");
    get_result;
    check8(rs[0], 8'h80, "L6 that SENSE INT had nothing queued yet");
    repeat (3) @(negedge clk);
    check_irq(1'b1, "L6 the change is presented after the result");
    check_edges(1, "L6 one edge");
    sense_is(8'hC9, "L6 AI|NR|1 again");
    sense_is(8'h80, "L6 then nothing");
    check_irq(1'b0, "L6 drained");

    // L7: a RECALIBRATE's completion after a stranded status is an edge too, and SENSE INT then
    // answers the recalibrated drive first (NP2kai FDC_SenceintStatus prefers stat[fdc.us]; MAME
    // the first filled drive): SE|0 = 0x20, then the queued AI|NR|1.
    // Drive 0 was re-armed by L4's swap: let its 20-frame insert delay run out first (the AI|0
    // it then announces is drained), so the RECALIBRATE finds it ready.
    frames(21);
    sense_is(8'hC0, "L7 drive 0 ready again (AI|0)");
    sense_is(8'h80, "L7 nothing else");
    mount_event(1);
    check_irq(1'b1, "L7 drive 1's change stands undrained");
    edges = 0;
    wr8(3'd1, 8'h07);
    check_irq(1'b0, "L7 the RECALIBRATE byte lowers INT");
    wr8(3'd1, 8'h00);
    time_irq(20000);
    check_irq(1'b1, "L7 the RECALIBRATE completes with INT");
    repeat (2) @(negedge clk);
    check_edges(1, "L7 ... as a rising edge");
    sense_is(8'h20, "L7 SE|0 first");
    sense_is(8'hC9, "L7 then the queued AI|NR|1");
    sense_is(8'h80, "L7 then nothing");
    check_irq(1'b0, "L7 drained");

  // ==== VERDICT ====
    if (fails != 0) $fatal(1, "TB_PC9821_FDC_INT_LINE: FAIL (%0d)", fails);
    $display("TB_PC9821_FDC_INT_LINE: PASS");
    $finish;
  end
endmodule
