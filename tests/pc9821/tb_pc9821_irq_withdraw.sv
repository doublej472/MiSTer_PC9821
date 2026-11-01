`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// IRQ9 is WITHDRAWN when the 0x064E status read lowers the IDE line and IRQ1 likewise on the keyboard line's falling edge (the machine measured post-ack IRR bit clear on both, docs/probes/IRQWD.TXT), while the as-yet-unmeasured IRQ15 still holds on its 0x128 read; the unmask after a withdrawn poll delivers nothing and after a surviving one exactly one INT/INTA. FAIL-FIRST: the old pure edge latch delivered a phantom IRQ9 here. IRQ1 is ALSO withdrawn while UNMASKED when the 0x41 read lowers the line, so a byte the guest polled while the request was latched is not dispatched a second time (the guest would read the stale data register and queue a duplicate key); the positive control still delivers it once while the line is high at the acknowledge.
//
// WHERE THIS COMES FROM. The 2026-10-02 real-Xe10 IRQWD capture
// (docs/probes/IRQWD.TXT) measured the masked-ack case the older reports only
// guessed at: IRQ9's post-ack IRR bit 1 is CLEAR after the 0x064E read, IRQ1's
// bit 1 is CLEAR after the 0x41 read, and IRQ12 HOLDS - so pc9821_pic's WD_MASK
// clears the latched request on the device line's falling edge while masked.
// IRQ15 was not triggered in that run (the calendar's interrupt was not enabled),
// so this bench pins the CORE's current hold for it as a CAPTURE-PENDING default.
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
  // 2026-10-02 machine capture (docs/probes/IRQWD.TXT). IRQ15 is not in WD_MASK -
  // its machine behaviour is still capture-pending - and the checks pin that.
  wire [7:0] slave_irq    = {cal_irq,    5'b00000, ata_irq,    1'b0};

  pc9821_interrupts #(.SYS_CLOCK_HZ(50_000_000)) irqblk (
      .clk(clk), .reset_n(rst_n),
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din),
      .io_dout(irq_dout),
      .master_cs(master_cs), .slave_cs(slave_cs), .pit_cs(1'b0),
      .keyboard_irq(keyboard_irq), .vsync_irq(1'b0), .master_aux_irq(4'b0000),
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

    // ---- C: a polled tick must SURVIVE the rate read (FAIL-FIRST) ----------
    // The 0x128 read lowers the calendar's level but must NOT withdraw the
    // PIC's IRR latch, so the unmask delivers exactly one INT/INTA (0x17).
    write_port(16'h000A, 8'h82);              // mask IRQ9 + IRQ15
    write_tick(8'h03);                        // 1/16 s = 100 cycles at 1600 Hz
    while (!cal_irq) @(posedge clk);
    repeat (4) @(posedge clk);
    read_tick;                                // the rate read under test
    repeat (4) @(posedge clk);
    if (cal_irq) fail("the 0x128 read did not lower the calendar request level");
    write_tick(8'h02);                        // rate off: no new ticks in the window
    base_count = inta_count;
    open_window;
    write_port(16'h000A, 8'h02);              // unmask IRQ15 (IRQ9 stays masked)
    repeat (200) @(posedge clk);
    if (!intr_seen || inta_count != base_count + 1)
      fail("the 0x128 read ate the pending IRQ15 request: an edge 8259 must hold a latched request across a status read");
    else if (inta_vector !== 8'h17)
      fail("IRQ15 vector not 0x17 (slave base 0x10 + 7)");
    eoi_both;

    // ---- D: positive control - an unacked tick must deliver ----------------
    base_count = inta_count;
    open_window;
    write_tick(8'h03);
    while (!cal_irq) @(posedge clk);
    write_port(16'h000A, 8'h02);              // keep IRQ9 masked, IRQ15 open; the pending tick delivers
    repeat (200) @(posedge clk);
    if (!intr_seen || inta_count != base_count + 1)
      fail("an unacked calendar tick did not deliver exactly one interrupt");
    else if (inta_vector !== 8'h17)
      fail("IRQ15 vector not 0x17 (slave base 0x10 + 7)");
    eoi_both;
    write_tick(8'h02);                        // rate off
    read_tick;                                // retire the level

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
