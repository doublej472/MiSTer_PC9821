`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// IRQ9 is WITHDRAWN when the 0x064E status read lowers the IDE line and IRQ1 likewise on the keyboard line's falling edge (the machine measured post-ack IRR bit clear on both, docs/probes/IRQWD.TXT), IRQ15 (the calendar) is withdrawn while masked when its line falls - at a tick's short low pulse, latched again at the pulse's end, and not at a 0x128 read (docs/probes/KIT2-XE10-AUDIT2.TXT CALIRR) - and delivers one INT 17h per tick with 0x128 never read (docs/probes/XE10T-XE10-AUDIT.TXT, the CAL and CASC rows); the unmask after a withdrawn poll delivers nothing and after a surviving one exactly one INT/INTA. FAIL-FIRST: the old pure edge latch delivered a phantom IRQ9 here. IRQ1 is ALSO withdrawn while UNMASKED when the 0x41 read lowers the line, so a byte the guest polled while the request was latched is not dispatched a second time (the guest would read the stale data register and queue a duplicate key); the positive control still delivers it once while the line is high at the acknowledge. IRQ11 (the 1 MB FDC, the real pc9821_fdc) is WITHDRAWN while masked when its line falls: the real Xe10's XE10T /FDC run (IR11 masked throughout; RECALIBRATE, SEEKs and SENSE INTERRUPT STATUS, READ ID, READ DATA, a final SENSE INTERRUPT STATUS drain) takes NO interrupt when the slave IMR is restored (docs/probes/XE10T-XE10-FDC.TXT `I FDC irq11_taken=0`), so a RECALIBRATE completion drained by SENSE INTERRUPT STATUS while masked delivers nothing at the unmask, while one left pending delivers exactly one INT 13h. FAIL-FIRST: the pure edge latch held the drained completion and delivered a phantom INT 13h (the core's own capture read irq11_taken=1). And the cascade follows the Xe10's XE10T /AUDIT CASC rows: the master's IR7 is withdrawn when the slave's request goes away (IRQ12 masked at the slave, or its line lowered with IRQ12 open, which withdraws the slave's own unmasked IRQ12 request too), and STI then delivers nothing; FAIL-FIRST, the master held IR7 and delivered a spurious interrupt. And the master's IR6 (INT2, the MPU-PC98's line) is withdrawn while masked when its line falls, as the Xe10 with an MPU-PC98 shows (docs/probes/MPUTEST-XE10.TXT `IRQ imr=757D before=1001 pend=9841 after=9801`: the masked IR6 set by the card's ACK clears when the ACK is read), so the unmask delivers nothing while an unread request delivers one INT 0Eh; FAIL-FIRST, the master held the latch and delivered it.
//
// WHERE THIS COMES FROM. The 2026-10-02 real-Xe10 IRQWD capture
// (docs/probes/IRQWD.TXT) measured the masked-ack case the older reports only
// guessed at: IRQ9's post-ack IRR bit 1 is CLEAR after the 0x064E read, IRQ1's
// bit 1 is CLEAR after the 0x41 read (IRQWD's IRQ12 row read its IRR before the line
// fell; XE10T /OPNA2 measures that drop, tb_pc9821_opna_xe10_rows) - so pc9821_pic's WD_MASK
// clears the latched request on the device line's falling edge while masked.
// IRQ15 was not triggered in that run; the XE10T /AUDIT run later measured it
// (docs/probes/XE10T-XE10-AUDIT.TXT: one INT 17h per tick read or not, and a masked
// slave IRR bit 7 that follows the line), and its CASC rows the cascade (sections H, I).
// The IRQ9 and IRQ1 cases are FAIL-FIRST: the pre-change pure edge latch kept the
// request and delivered a phantom. The VSYNC.TXT in-service hold (IRQ2) is a
// POSITIVE CONTROL: IRQ2 is not in WD_MASK and must keep holding.
//
// Both acking reads are pinned here - the IDE's 0x064E and the calendar's 0x128 - through
// the real pc9821_ata / pc9821_calendar, the real pc9821_interrupts master/slave pair and
// the real pc9821_inta_bridge, with a z486-shaped INTA client so the assertion is about
// INTAs taken, not about an internal flag. The delivery count is the instrument: the client
// answers EVERY asserted intr, so a withdrawn request is a missing delivery where the edge
// spec says exactly one must arrive. The expected vectors are the firmware's own
// programming (ICW2 0x08 master / 0x10 slave, so slave IRQ9 answers 0x11 and IRQ15 answers
// 0x17 - the "INT 11h" of the freeze report).

module tb_pc9821_irq_withdraw;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  // The shared I/O bus. The ATA takes it un-gated (its own address decode + the
  // 0x0432 bank window decide), the PIC pair takes it with the selects below, and
  // the calendar's 0x128 strobe is driven decoded (pc9821_system owns that decode
  // in the built core; this bench drives the strobe the decode produces).
  reg io_wr = 0, io_rd = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] ata_dout, irq_dout;
  reg master_cs = 0, slave_cs = 0;

  // pc9821_ata's block interface. The requests here are aborts (a READ SECTORS
  // whose LBA is past the end of the image), which complete without a block
  // fetch, so block_done stays 0 for the whole run. The fetch CONTENTS are not
  // the subject here (tb_pc9821_ata_datapath owns them), only the
  // request/completion handshake and the IRQ level it raises.
  wire ata_irq;
  wire block_read, block_write;
  wire [31:0] block_lba;
  reg block_done = 0, block_error = 0;
  reg block_buf_we = 0;
  reg [7:0] block_buf_addr = 0;
  reg [15:0] block_buf_data = 0;
  reg [7:0] block_rd_addr = 0;
  wire [15:0] block_rd_data;
  wire [7:0] ata_dbg_state;
  wire [31:0] ata_dbg_cmd, ata_dbg_lba;
  wire [15:0] ata_dbg_sec;

  // pc9821_calendar's front panel.
  reg cmd_we = 0, mode_we = 0, tick_we = 0, tick_rd = 0;
  reg [7:0] cmd_din = 0, mode_din = 0, tick_din = 0;
  wire [7:0] mode_dout, tick_dout;
  wire cal_cdat, cal_irq;

  // The keyboard request line, driven the way pc9821_kbd drives it: high while a
  // byte is pending, low the cycle after the 0x41 data read (`irq = status[1] &&
  // !st_read ...`). The IRQ1 check below lowers it by hand.
  reg keyboard_irq = 0;

  // pc9821_interrupts' CPU side.
  wire cpu_intr;
  reg cpu_inta = 0;
  wire [31:0] cpu_inta_din;
  wire cpu_inta_ready;
  wire pit_out0, pit_out1, pit_out2;
  wire [7:0] dbg_imr, dbg_irr, dbg_isr;

  // The delivery counters the checks read. intr_seen is a sticky "INT asserted at
  // all" flag for the positive-control windows; inta_count counts completed
  // two-cycle acknowledges; inta_vector is the vector the last one carried.
  integer intr_pulses = 0;
  integer inta_count = 0;
  reg [7:0] inta_vector = 0;
  reg intr_seen = 0;

  // ==== DUT ====
  // The slave lines as pc9821_system wires them: bit 1 = IRQ9 (the IDE), bit 7 =
  // IRQ15 (the calendar). pc9821_pic's WD_MASK makes the IRQ1/IRQ9 falling edges
  // (and IRQ0 on the master) withdraw the latched request while masked, per the
  // 2026-10-02 machine capture (docs/probes/IRQWD.TXT); IRQ15 (masked) and IRQ12 (also
  // unmasked) per XE10T /AUDIT (docs/probes/XE10T-XE10-AUDIT.TXT), sections C, D, H, I.
  // Bit 3 = IRQ11, the 1 MB FDC's interrupt (pc9821_iobus routes pc9821_fdc's `irq` there
  // while the 0x00BE strap selects the 1 MB interface, its reset state).
  wire fdc_irq;
  // Bit 4 = IRQ12, the 86 board's OPNA timer line, driven by hand like the keyboard's.
  reg opna_irq = 0;
  // Master IR6 (INT2), the MPU-PC98's request line (pc9821_system wires master_aux_irq's bit 3
  // to the MPU), driven by hand: high while a response byte is queued, low after its read.
  reg mpu_irq = 0;
  wire [7:0] slave_irq    = {cal_irq,    2'b00, opna_irq, fdc_irq, 1'b0, ata_irq,    1'b0};

  pc9821_interrupts #(.SYS_CLOCK_HZ(50_000_000)) irqblk (
      .clk(clk), .reset_n(rst_n),
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din),
      .io_dout(irq_dout),
      .master_cs(master_cs), .slave_cs(slave_cs), .pit_cs(1'b0),
      .keyboard_irq(keyboard_irq), .vsync_irq(1'b0), .master_aux_irq({mpu_irq, 3'b000}),
      .slave_irq(slave_irq),
      .cpu_intr(cpu_intr), .cpu_inta(cpu_inta),
      .cpu_inta_din(cpu_inta_din), .cpu_inta_ready(cpu_inta_ready),
      .pit_out0(pit_out0), .pit_out1(pit_out1), .pit_out2(pit_out2),
      .dbg_imr(dbg_imr), .dbg_irr(dbg_irr), .dbg_isr(dbg_isr)
  );

  pc9821_ata ata (
      // The channel's slave (device 1): no image, so the master answers for DEV=1 as before.

      .clk(clk), .rst_n(rst_n),
      .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din),
      .io_dout(ata_dout),
      .mounted(1'b1), .readonly(1'b0), .capacity(32'd100000),
      .block_read(block_read), .block_write(block_write), .block_lba(block_lba),
      .block_done(block_done), .block_error(block_error),
      .block_buf_we(block_buf_we), .block_buf_addr(block_buf_addr),
      .block_buf_data(block_buf_data),
      .block_rd_addr(block_rd_addr), .block_rd_data(block_rd_data),
      .irq(ata_irq),
      .dbg_state(ata_dbg_state), .dbg_cmd(ata_dbg_cmd),
      .dbg_lba(ata_dbg_lba), .dbg_sec(ata_dbg_sec)
  );

  // 1600 Hz "clk_sys": the 1/16 s tick is then 100 cycles, so a tick is a
  // bench-sized wait. The rates are the machine's own (the divider is
  // SYS_CLOCK_HZ-derived, pc9821_calendar.sv), only the clock is shrunk.
  pc9821_calendar #(.SYS_CLOCK_HZ(1600)) cal (
      .clk(clk), .rst_n(rst_n),
      .rtc_bcd(56'd0), .rtc_load(1'b0),
      .cmd_we(cmd_we), .cmd_din(cmd_din),
      .mode_we(mode_we), .mode_din(mode_din), .mode_dout(mode_dout),
      .tick_we(tick_we), .tick_rd(tick_rd), .tick_din(tick_din),
      .tick_dout(tick_dout), .cdat(cal_cdat),
      .irq(cal_irq)
  );

  // The 1 MB FDC at 0x90 (MSR) / 0x92 (data) / 0x94, no medium in either drive: a
  // RECALIBRATE of the equipped unit 0 then completes through the deferred path (the
  // interrupt rises at the completion and SENSE INTERRUPT STATUS's drain lowers it), the
  // same line shape a medium's SEEK/RECALIBRATE gives (tb_pc9821_fdc_conform pins it).
  wire       fdc_cs = (io_addr == 16'h0090) || (io_addr == 16'h0092) || (io_addr == 16'h0094);
  wire [2:0] fdc_a  = (io_addr == 16'h0090) ? 3'd0 : (io_addr == 16'h0092) ? 3'd1 : 3'd2;
  wire [7:0] fdc_dout;
  pc9821_fdc fdc (
      .clk(clk), .reset(!rst_n), 
      .cs(fdc_cs), .addr(fdc_a), .wr(io_wr), .rd(io_rd), .din(io_din), .dout(fdc_dout),
      .irq(fdc_irq), .res_done(), .win_2dd(1'b0), .strap_2hd(),
      .media_present(4'b0000), .writeprotect(4'b0000), .media_chg(4'b0000),
      .frame_tick(1'b0),
      .media_req(), .media_req_hdr(), .media_unit(), .media_c(), .media_h(), .media_tc(),
      .media_hd(), .media_mf(), .media_2hd(), .media_rpm(), .media_r(), .media_n(),
      .media_idx(), .media_wr(), .media_din(), .media_abort(),
      .media_ready(1'b1), .media_rdy(1'b0), .media_hdrv(1'b0), .media_err(1'b0),
      .media_dout(8'h00), .media_hr(8'h00), .media_hn(8'h00), .media_hs(8'h00),
      .media_adv(),
      .dma_drq(), .dma_dack(1'b0), .dma_stb(1'b0), .dma_tc(1'b0), .dma_dout(),
      .dma_we(1'b0), .dma_din(8'h00),
      .dbg_state(), .dbg_cmd(), .dbg_result(), .dbg_chrn()
  );

  integer errors = 0;
  // ==== STIMULUS ====

  task automatic fail(input [8*120-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task automatic set_selects(input [15:0] portnum);
    begin
      master_cs = (portnum == 16'h0000) || (portnum == 16'h0002);
      slave_cs  = (portnum == 16'h0008) || (portnum == 16'h000A);
    end
  endtask

  task automatic write_port(input [15:0] portnum, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = portnum;
      set_selects(portnum);
      io_din = data;
      io_wr = 1;
      @(negedge clk);
      io_wr = 0;
    end
  endtask

  // A one-cycle read strobe. The 0x064E read is the IDE ack under test; the
  // data returned is not the subject (tb_pc9821_ata_regs pins the task file).
  task automatic read_port(input [15:0] portnum);
    begin
      @(negedge clk);
      io_addr = portnum;
      set_selects(portnum);
      io_rd = 1;
      @(negedge clk);
      io_rd = 0;
    end
  endtask

  task automatic write_tick(input [7:0] data);
    begin
      @(negedge clk);
      tick_din = data;
      tick_we = 1;
      @(negedge clk);
      tick_we = 0;
    end
  endtask

  task automatic read_tick;
    begin
      @(negedge clk);
      tick_rd = 1;
      @(negedge clk);
      tick_rd = 0;
    end
  endtask

  task automatic init_pic(
      input [15:0] command_port, input [15:0] data_port,
      input [7:0] vector, input [7:0] icw3, input [7:0] icw4,
      input [7:0] mask);
    begin
      write_port(command_port, 8'h11);
      write_port(data_port, vector);
      write_port(data_port, icw3);
      write_port(data_port, icw4);
      write_port(data_port, mask);
    end
  endtask

  // EOI both controllers, slave then master (the order tb_pc9821_interrupts and
  // the disk ISR use).
  task automatic eoi_both;
    begin
      write_port(16'h0008, 8'h20);
      write_port(16'h0000, 8'h20);
    end
  endtask

  // A request raise with no data path: a READ SECTORS command whose LBA is past
  // the end of the image aborts (pc9821_ata's command arm -> abort_command), and
  // the abort is a completion that raises the level subject to nIEN
  // (`irq <= !irq_disable`, the same rule every completion follows). NP2kai raises
  // at the abort through the same setintr path, so the raise shape is the
  // reference's.
  task automatic ata_raise_via_abort;
    begin
      write_port(16'h0432, 8'h00);   // the bank whose window has the interface
      write_port(16'h064C, 8'h4F);   // LBA mode, LBA[27:24] = 0xF
      write_port(16'h0644, 8'hFF);   // sector count
      write_port(16'h0646, 8'hFF);
      write_port(16'h0648, 8'hFF);
      write_port(16'h064A, 8'hFF);
      write_port(16'h064E, 8'h20);   // READ SECTORS at LBA 0xFFFFFFFF -> abort
      repeat (4) @(posedge clk);
    end
  endtask

  // The z486 side of the INTA pair: cpu_inta is a LEVEL held until the bridge
  // answers with cpu_inta_ready (src/z486/memory.sv), released for a cycle
  // between the two bus cycles (the bridge's taken flag needs a real release,
  // pc9821_inta_bridge.sv). It answers EVERY asserted intr, so a delivered or a
  // missing interrupt is a count - which is what every check below reads.
  reg intr_prev = 0;
  reg inta_busy = 0;
  // When 0 the client holds the acknowledge off, the way a guest with IF clear (or
  // inside another handler) delays taking an already-asserted request.
  reg ack_enable = 1;
  always @(negedge clk) begin
    if (!rst_n) begin
      intr_prev = 0;
    end else begin
      if (cpu_intr && !intr_prev) intr_pulses = intr_pulses + 1;
      intr_prev = cpu_intr;
      if (cpu_intr) intr_seen = 1;
      if (cpu_intr && !inta_busy && ack_enable) begin
        inta_busy = 1;
        cpu_inta = 1;
        @(negedge clk);
        while (!cpu_inta_ready) @(negedge clk);
        cpu_inta = 0;
        @(negedge clk);
        cpu_inta = 1;
        @(negedge clk);
        while (!cpu_inta_ready) @(negedge clk);
        inta_vector = cpu_inta_din[7:0];
        inta_count = inta_count + 1;
        cpu_inta = 0;
        @(negedge clk);
        inta_busy = 0;
      end
    end
  end

  task automatic open_window;
    begin
      @(negedge clk);
      intr_seen = 0;
    end
  endtask

  integer base_count;
  integer k, w;
  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;

    // The firmware's own programming shape (tb_pc9821_interrupts pins the ICW4
    // values against the machine's BANK4@0x4BB1-0x4BC3): master base 0x08 with
    // only the cascade (IRQ7) unmasked, slave base 0x10 with everything masked.
    // The calendar's tick is OFF (rate 2) so section A is quiet.
    init_pic(16'h0000, 16'h0002, 8'h08, 8'h80, 8'h1D, 8'h7F);
    init_pic(16'h0008, 16'h000A, 8'h10, 8'h07, 8'h01, 8'hFF);
    write_tick(8'h02);
    repeat (4) @(posedge clk);

    // ---- A: a polled request IS WITHDRAWN by the status read (machine) -----
    // IRQ9 masked at the slave, the request raised, then the ROM's own polled
    // 0x064E status read lowers the device line. The machine WITHDRAWS the
    // latched request on that falling edge (IRQWD 2026-10-02: post-ack IRR bit 1
    // clear), so the unmask must deliver NOTHING. FAIL-FIRST against the old
    // pure edge latch, which delivered one phantom INT 11h here.
    write_port(16'h000A, 8'h82);              // mask IRQ9 + IRQ15 (IMR bits 1 and 7)
    ata_raise_via_abort;
    if (!ata_irq) fail("the abort did not raise the IDE request level");
    repeat (4) @(posedge clk);
    read_port(16'h064E);                      // the status read under test
    repeat (4) @(posedge clk);
    if (ata_irq) fail("the 0x064E read did not lower the IDE request level");
    base_count = inta_count;
    open_window;
    write_port(16'h000A, 8'h80);              // unmask IRQ9 (IRQ15 stays masked)
    repeat (200) @(posedge clk);
    if (intr_seen || inta_count != base_count)
      fail("the 0x064E read did NOT withdraw IRQ9: the machine withdraws it (IRQWD), so the unmask must deliver nothing");
    eoi_both;

    // ---- B: positive control - the SAME raise with no poll must deliver ----
    base_count = inta_count;
    open_window;
    ata_raise_via_abort;
    repeat (200) @(posedge clk);
    if (!intr_seen || inta_count != base_count + 1)
      fail("an unacked IRQ9 request did not deliver exactly one interrupt");
    else if (inta_vector !== 8'h11)
      fail("IRQ9 vector not 0x11 (slave base 0x10 + 1)");
    eoi_both;
    read_port(16'h064E);                      // the ISR's own ack: retire the level

    // ---- C: a masked IRQ15 request follows the calendar's line (machine) ---
    // The Xe10's slave IRR bit 7 follows the calendar's line while IRQ15 is masked (the XE10T
    // /AUDIT CASC rows read it set and then clear with IR7 masked, docs/probes/XE10T-XE10-AUDIT.TXT
    // CASC_CTL `s_irr=90 ... s_irr1=00`), and kit 2's CALIRR rows sampled that bit: high but for
    // a 1-2 ARTIC-tick low pulse at each tick, the same with a 0x128 read at every rise
    // (docs/probes/KIT2-XE10-AUDIT2.TXT:27-41, `cfg=81 mode=R ... ones=97790`). So the masked
    // request is latched at the pulse's end, withdrawn at the next tick's fall, latched again,
    // and a 0x128 read leaves it: the unmask then delivers one INT 17h.
    write_port(16'h000A, 8'h82);              // mask IRQ9 + IRQ15
    write_tick(8'h83);                        // enabled, 1/16 s = 100 cycles at 1600 Hz
    while (!cal_irq) @(posedge clk);          // the first tick's pulse has ended
    repeat (4) @(posedge clk);
    if (!irqblk.slave.ir_latch[7]) fail("the masked calendar tick did not latch in the slave IRR");
    read_tick;
    repeat (4) @(posedge clk);
    if (!cal_irq) fail("the 0x128 read lowered the calendar line (the Xe10's stays high)");
    if (!irqblk.slave.ir_latch[7])
      fail("the 0x128 read withdrew the masked IRQ15 request (the Xe10's IRR stays set)");
    while (cal_irq) @(posedge clk);           // the next tick's pulse
    repeat (2) @(posedge clk);
    while (!cal_irq) @(posedge clk);
    repeat (4) @(posedge clk);
    if (!irqblk.slave.ir_latch[7])
      fail("the masked IRQ15 request was not latched again at the next pulse's end");
    write_tick(8'h82);                        // rate off: the line drops, no new ticks
    repeat (4) @(posedge clk);
    if (irqblk.slave.ir_latch[7])
      fail("the masked IRQ15 request survived its line's fall at the rate-off write");
    base_count = inta_count;
    open_window;
    write_port(16'h000A, 8'h02);              // unmask IRQ15 (IRQ9 stays masked)
    repeat (200) @(posedge clk);
    if (intr_seen || inta_count != base_count)
      fail("a withdrawn IRQ15 request delivered at the unmask");
    write_port(16'h000A, 8'h82);

    // ---- D: one IRQ15 per tick, 0x128 never read (machine) -----------------
    // The Xe10 takes an INT 17h on every tick whether or not the handler reads 0x128
    // (docs/probes/XE10T-XE10-AUDIT.TXT `X AUDIT CAL cfg=81 mode=N n=16`, `cfg=83 mode=N n=8`
    // in 0.5 s). Here the handler only EOIs, and four ticks deliver four INT 17h (0x17).
    // FAIL-FIRST: the request was held until a 0x128 read, so the second never came.
    write_port(16'h000A, 8'h02);              // IRQ15 open, IRQ9 masked
    base_count = inta_count;
    write_tick(8'h83);
    for (k = 1; k <= 4; k = k + 1) begin
      for (w = 0; (w < 400) && (inta_count < base_count + k); w = w + 1) @(posedge clk);
      if (inta_count != base_count + k)
        fail("a calendar tick delivered no INT 17h with 0x128 unread (one per tick on the Xe10)");
      else if (inta_vector !== 8'h17)
        fail("IRQ15 vector not 0x17 (slave base 0x10 + 7)");
      eoi_both;
    end
    write_tick(8'h82);                        // rate off
    write_port(16'h000A, 8'h82);

    // ---- E: IRQ1 is withdrawn by its line's falling edge (machine) ---------
    // Master IRQ1 masked, the keyboard line raised, then lowered (pc9821_kbd
    // lowers it on the 0x41 read). The machine withdraws the latch on that
    // falling edge (IRQWD 2026-10-02: post-ack IRR bit 1 clear), so the unmask
    // delivers nothing. Positive control: an unacked raise does deliver (0x09).
    write_port(16'h0002, 8'h7F);              // master: IRQ0-6 masked, cascade open
    keyboard_irq = 1'b1;
    repeat (4) @(posedge clk);
    keyboard_irq = 1'b0;                      // the acking read's falling edge
    repeat (4) @(posedge clk);
    base_count = inta_count;
    open_window;
    write_port(16'h0002, 8'h7D);              // unmask IRQ1 (bit 1)
    repeat (200) @(posedge clk);
    if (intr_seen || inta_count != base_count)
      fail("the falling edge did NOT withdraw the masked IRQ1 request (the machine withdraws it)");
    write_port(16'h0002, 8'h7F);              // re-mask IRQ1
    keyboard_irq = 1'b1;                      // positive control: raise then deliver
    base_count = inta_count;
    open_window;
    write_port(16'h0002, 8'h7D);              // unmask IRQ1
    repeat (200) @(posedge clk);
    if (!intr_seen || inta_count != base_count + 1)
      fail("an unacked IRQ1 request did not deliver exactly one interrupt");
    else if (inta_vector !== 8'h09)
      fail("IRQ1 vector not 0x09 (master base 0x08 + 1)");
    keyboard_irq = 1'b0;
    write_port(16'h0002, 8'h7F);
    eoi_both;

    // ---- F: an UNMASKED IRQ1 is withdrawn by its acking read (FAIL-FIRST) --
    // The keyboard line falls only when the guest has just read the data register.
    // If that read lands after the request latched but before the CPU took it
    // (the guest polled the byte with interrupts delayed), the request is spent:
    // holding it dispatches the consumed byte, and the guest's INT 09h reads the
    // stale data register and queues a duplicate key. The positive control is the
    // same raise with the line still high at the acknowledge.
    write_port(16'h0002, 8'h7D);              // IRQ1 unmasked, as DOS leaves it
    ack_enable = 0;                            // the CPU has not taken it yet
    keyboard_irq = 1'b1;
    repeat (8) @(posedge clk);
    if (!dbg_irr[1]) fail("the unmasked IRQ1 raise did not latch in the IRR");
    keyboard_irq = 1'b0;                       // the acking 0x41 data read
    repeat (8) @(posedge clk);
    base_count = inta_count;
    open_window;
    ack_enable = 1;                            // interrupts can be taken again
    repeat (200) @(posedge clk);
    if (intr_seen || inta_count != base_count)
      fail("an UNMASKED IRQ1 whose acking 0x41 read lowered the line still delivered: the consumed byte is dispatched again");
    base_count = inta_count;
    open_window;
    keyboard_irq = 1'b1;                       // positive control: still high at the ack
    repeat (200) @(posedge clk);
    if (!intr_seen || inta_count != base_count + 1)
      fail("an unacked unmasked IRQ1 did not deliver exactly one interrupt");
    else if (inta_vector !== 8'h09)
      fail("IRQ1 vector not 0x09 (master base 0x08 + 1)");
    keyboard_irq = 1'b0;
    write_port(16'h0002, 8'h7F);
    eoi_both;

    // ---- G: a masked IRQ11 drained by SENSE INTERRUPT STATUS is withdrawn (machine) --
    // The XE10T /FDC run masks IR11 (slave IMR bit 3) for its whole section, runs its
    // RECALIBRATE/SEEK/SENSE INTERRUPT STATUS pairs, READ IDs and READ DATAs, drains every
    // pending status with SENSE INTERRUPT STATUS, then restores the slave IMR with an
    // EOI-only handler on vector 0x13 and counts what arrives: the real Xe10 takes NONE
    // (docs/probes/XE10T-XE10-FDC.TXT `I FDC irq11_taken=0`; the sequence is
    // tools/hwprobe/xe10t/sec_storage.inc sec_fdc .. fdc_exit). The FDC's line rose at each
    // completion and fell at each drain while masked, so the machine's IRR follows that line
    // as it does for IRQ9 (IRQWD). Here: one RECALIBRATE completion and its drain, masked.
    write_port(16'h000A, 8'h8A);              // mask IRQ9, IRQ11, IRQ15
    write_port(16'h0092, 8'h07);              // RECALIBRATE
    write_port(16'h0092, 8'h00);              //   unit 0
    while (!fdc_irq) @(posedge clk);          // the completion raises the line
    repeat (4) @(posedge clk);
    if (!irqblk.slave.ir_latch[3])
      fail("the masked FDC completion did not latch in the slave IRR");
    write_port(16'h0092, 8'h08);              // SENSE INTERRUPT STATUS
    read_port(16'h0092);                      //   ST0
    read_port(16'h0092);                      //   PCN: the drain lowers the line
    repeat (4) @(posedge clk);
    if (fdc_irq) fail("SENSE INTERRUPT STATUS did not lower the FDC request line");
    base_count = inta_count;
    open_window;
    write_port(16'h000A, 8'h82);              // the as-found IMR back: IRQ11 unmasked
    repeat (200) @(posedge clk);
    if (intr_seen || inta_count != base_count)
      fail("a drained, masked IRQ11 delivered at the unmask: the machine takes none (XE10T-XE10-FDC irq11_taken=0)");
    eoi_both;                                 // (retire a phantom so the control below is independent)
    // Positive control: a completion still pending at the unmask delivers exactly one INT 13h.
    write_port(16'h000A, 8'h8A);              // mask IRQ11 again
    write_port(16'h0092, 8'h07);
    write_port(16'h0092, 8'h00);
    while (!fdc_irq) @(posedge clk);
    repeat (4) @(posedge clk);
    base_count = inta_count;
    open_window;
    write_port(16'h000A, 8'h82);              // unmask with the line still high
    repeat (200) @(posedge clk);
    if (!intr_seen || inta_count != base_count + 1)
      fail("a pending FDC completion did not deliver exactly one interrupt at the unmask");
    else if (inta_vector !== 8'h13)
      fail("IRQ11 vector not 0x13 (slave base 0x10 + 3)");
    eoi_both;
    write_port(16'h0092, 8'h08);              // retire the completion
    read_port(16'h0092);
    read_port(16'h0092);

    // ---- H: the master's IR7 is withdrawn when the slave's request goes away (machine) --
    // XE10T /AUDIT CASC (docs/probes/XE10T-XE10-AUDIT.TXT): an OPNA timer flag on IRQ12, IF
    // clear, the master's IR7 open. With IRQ12 open at the slave the master IRR reads 80
    // (`m_on=80`); masking IRQ12 at the slave leaves it 00 at once (`m_off=00 m_off2=00`), and
    // STI then takes nothing (`n17=0 n0f=0`). CASC_CTL is the control: re-opened, the real
    // INT 14h arrives (`n14=1`). FAIL-FIRST: the master held IR7 and took a spurious INT 17h
    // (the core's rc6 capture, docs/probes/core/XE10T-CORE-rc6-s3-AUDIT2.TXT `m_off=81`).
    write_port(16'h0002, 8'h7F);              // master: the cascade (IR7) open
    write_port(16'h000A, 8'hFF);              // slave: everything masked
    ack_enable = 0;                           // IF clear
    write_port(16'h000A, 8'hEF);              // IRQ12 open
    opna_irq = 1'b1;                          // the timer flag
    repeat (8) @(posedge clk);
    if (!dbg_irr[7]) fail("the slave's IRQ12 request did not reach the master's IR7 (m_on=80)");
    write_port(16'h000A, 8'hFF);              // mask IRQ12 at the slave
    repeat (8) @(posedge clk);
    if (dbg_irr[7]) fail("the master held IR7 after the slave's request went away (the Xe10 m_off=00)");
    base_count = inta_count;
    open_window;
    ack_enable = 1;                           // STI
    repeat (200) @(posedge clk);
    if (intr_seen || inta_count != base_count)
      fail("a withdrawn cascade request delivered an interrupt (the Xe10 n17=0 n0f=0)");
    // CASC_CTL: the same request with IRQ12 re-opened is the real INT 14h.
    base_count = inta_count;
    open_window;
    write_port(16'h000A, 8'hEF);
    repeat (200) @(posedge clk);
    if (!intr_seen || inta_count != base_count + 1)
      fail("the re-opened IRQ12 request did not deliver exactly one interrupt (the Xe10 n14=1)");
    else if (inta_vector !== 8'h14)
      fail("IRQ12 vector not 0x14 (slave base 0x10 + 4)");
    opna_irq = 1'b0;
    eoi_both;
    write_port(16'h000A, 8'hFF);

    // ---- I: an UNMASKED IRQ12 request goes when the chip's flag is reset (machine) --
    // XE10T /AUDIT CASC_DEV: the same, but IRQ12 stays open and the flag is reset at the chip
    // (0x27 <- 30): the slave IRR bit 4 is clear after it (`s_irr=90 ... s_irr1=80`), the
    // master's IR7 too (`m_off=00`), and STI delivers nothing (`n14=0 n17=0`). FAIL-FIRST: the
    // core held both latches and took the INT 14h (rc6 `m_off=81 ... n14=1`).
    ack_enable = 0;
    write_port(16'h000A, 8'hEF);
    opna_irq = 1'b1;
    repeat (8) @(posedge clk);
    if (!irqblk.slave.ir_latch[4] || !dbg_irr[7]) fail("the IRQ12 request did not latch (s_irr 10, m_on 80)");
    opna_irq = 1'b0;                          // 0x27 <- 30: the flag reset at the chip
    repeat (8) @(posedge clk);
    if (irqblk.slave.ir_latch[4]) fail("the slave held the unmasked IRQ12 request after its line fell (the Xe10 s_irr1=80)");
    if (dbg_irr[7]) fail("the master held IR7 after the slave's request went away (CASC_DEV m_off=00)");
    base_count = inta_count;
    open_window;
    ack_enable = 1;
    repeat (200) @(posedge clk);
    if (intr_seen || inta_count != base_count)
      fail("a withdrawn IRQ12 request delivered an interrupt (the Xe10 n14=0)");
    write_port(16'h000A, 8'hFF);

    // ---- J: a masked IR6 (the MPU-PC98's INT2) request follows its line (machine) --
    // MPUTEST on the Xe10 with an MPU-PC98 (docs/probes/MPUTEST-XE10.TXT `IRQ imr=757D
    // before=1001 pend=9841 after=9801 ack=FE`): with the master IMR 0x7D (IR6 masked) the
    // card's ACK sets master IRR bit 6 (01 -> 41), and reading the ACK lowers the card's line
    // and the IRR bit goes with it (41 -> 01). So the unmask afterwards delivers nothing;
    // positive control: an unread request does deliver (vector 0x0E).
    write_port(16'h0002, 8'h7D);              // master: the capture's IMR (IR6 masked)
    mpu_irq = 1'b1;                           // the ACK byte is queued
    repeat (8) @(posedge clk);
    if (!dbg_irr[6]) fail("the masked IR6 request did not latch (the capture's pend=..41)");
    mpu_irq = 1'b0;                           // the 0xE0D0 read empties the queue
    repeat (8) @(posedge clk);
    if (dbg_irr[6]) fail("the master held the masked IR6 request after its line fell (the Xe10 after=..01)");
    base_count = inta_count;
    open_window;
    write_port(16'h0002, 8'h3D);              // unmask IR6
    repeat (200) @(posedge clk);
    if (intr_seen || inta_count != base_count)
      fail("a withdrawn IR6 request delivered at the unmask");
    write_port(16'h0002, 8'h7D);              // re-mask IR6
    mpu_irq = 1'b1;                           // positive control: raise, do not read
    repeat (8) @(posedge clk);
    base_count = inta_count;
    open_window;
    write_port(16'h0002, 8'h3D);
    repeat (200) @(posedge clk);
    if (!intr_seen || inta_count != base_count + 1)
      fail("an unread IR6 request did not deliver exactly one interrupt");
    else if (inta_vector !== 8'h0E)
      fail("IR6 vector not 0x0E (master base 0x08 + 6)");
    mpu_irq = 1'b0;
    write_port(16'h0002, 8'h7F);
    eoi_both;

    repeat (4) @(posedge clk);
    // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_IRQ_WITHDRAW: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_IRQ_WITHDRAW: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_IRQ_WITHDRAW: TIMEOUT");
  end

endmodule
