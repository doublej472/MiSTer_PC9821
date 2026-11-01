`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The interrupt path from the device pins to the CPU-facing ports: master ICW4 programming, slave IRQ9 reaching the vector, the cascade acknowledge, the special fully nested mode the authentic disk ISR relies on, and the atomic acknowledge (a higher-priority request arriving between the vector being published and the acknowledge edge must not leave the master's ISR bit naming a different IRQ than the vector). No CPU is instantiated, so 'end to end' means to this module's ports. The interrupts.md F1 addition pins the SPURIOUS-vector selection: after a prior cascade ack, a master-level spurious INTA (the request withdrawn by an IMR write before the handshake) must answer the MASTER's icw2_vec|7 = 0x0F, never the slave's parked 0x17 - the ack event decides the source, not the stale int_acked_irq (FAIL-FIRST: the old mux answers 0x17).
//
// The interrupt path from the device pins to the CPU-facing ports: master ICW4 programming, slave IRQ9 reaching the vector, the cascade acknowledge, the special fully nested mode the authentic disk ISR relies on, the atomic acknowledge (a higher-priority request arriving between the vector being published and the acknowledge edge must not leave the master's ISR bit naming a different IRQ than the vector), and review interrupts.md F1: a master-level SPURIOUS INTA after a prior cascade ack must answer the MASTER's spurious vector 0x0F, never the slave's 0x17 (FAIL-FIRST: the stale-int_acked_irq mux answers 0x17 there). No CPU is instantiated, so 'end to end' means to this module's ports.


module tb_pc9821_interrupts;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset_n = 0;
  reg io_wr = 0, io_rd = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] io_dout;
  // The three selects this block takes from its host. pc9821_system decodes them
  // in pc9821_device_select.sv and tb_pc9821_device_select.sv sweeps every port
  // address against that decode; here they only have to follow one port number,
  // so this bench drives the RULE the same way (one line each) rather than
  // carrying a second copy of the table.
  reg master_cs = 0, slave_cs = 0, pit_cs = 0;
  reg keyboard_irq = 0, vsync_irq = 0;
  reg [3:0] master_aux_irq = 0;
  reg [7:0] slave_irq = 0;
  wire cpu_intr;
  reg cpu_inta = 0;
  wire [31:0] cpu_inta_din;
  wire cpu_inta_ready, pit_out0;
  // Channel 2 is the beeper's tone (pc9821_system ANDs it with the system port's
  // mute bit); this bench does not drive it, but `dut (.*)` needs every port
  // named.
  wire pit_out1;
  wire pit_out2;

  // Telemetry taps (see pc9821_system's watchdog message).
  wire [7:0] dbg_imr, dbg_irr, dbg_isr;
  wire [7:0] dbg_s_imr, dbg_s_isr;

  // The vector the ack-race case delivered, and the IRQ it named.
  reg [7:0] race_vec;

  // ==== DUT ====
  pc9821_interrupts #(.SYS_CLOCK_HZ(50_000_000)) dut (.*);

  integer errors = 0;
  // ==== STIMULUS ====

  task automatic set_selects(input [15:0] portnum);
    begin
      master_cs = (portnum == 16'h0000) || (portnum == 16'h0002);
      slave_cs  = (portnum == 16'h0008) || (portnum == 16'h000A);
      pit_cs    = ((portnum[15:3] == 13'h000E) || (portnum[15:3] == 13'h07FB)) &&
                  portnum[0];
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

  task automatic inta_cycle;
    begin
      @(negedge clk);
      cpu_inta = 1;
      while (!cpu_inta_ready) @(negedge clk);
      @(negedge clk);
      cpu_inta = 0;
      repeat (2) @(negedge clk);
    end
  endtask

  // Raise one IRQ line, acknowledge it, and require the vector the firmware programs:
  // the master carries base 0x08 and the slave 0x10, so IRQ n answers 0x08 + n and a
  // slave line n answers 0x10 + (n - 8). Only the line under test is unmasked, and the
  // cascade (master IRQ7) is left unmasked for a slave line.
  task automatic check_line(input integer line, input [7:0] want);
    begin
      write_port(16'h0002, 8'hFF);                       // mask everything
      write_port(16'h000A, 8'hFF);
      if (line < 8)
        write_port(16'h0002, ~(8'h01 << line[2:0]));
      else begin
        write_port(16'h0002, 8'h7F);                     // master: the cascade only
        write_port(16'h000A, ~(8'h01 << (line[2:0] - 3'd0)));
      end
      if      (line == 1) keyboard_irq = 1;
      else if (line == 2) vsync_irq = 1;
      else if (line < 7)  master_aux_irq[line - 3] = 1;
      else                slave_irq[line - 8] = 1;
      repeat (8) @(posedge clk);
      if (!cpu_intr) begin
        $display("FAIL IRQ%0d did not assert INT", line);
        errors = errors + 1;
      end
      // One inta_cycle is the whole acknowledge: measured, the vector is valid and the
      // in-service bit is set when it returns. A second pulse is a spurious read and
      // correctly answers 0.
      // Two INTA assertions are one acknowledge: the bridge answers the first with a
      // dummy cycle and delivers the vector on the second. The vector is only valid
      // after the second, so sample there.
      inta_cycle();
      inta_cycle();
      if (cpu_inta_din[7:0] !== want) begin
        $display("FAIL IRQ%0d vector %02x, want %02x", line, cpu_inta_din[7:0], want);
        errors = errors + 1;
      end
      repeat (4) @(posedge clk);
      keyboard_irq = 0; vsync_irq = 0; master_aux_irq = 0; slave_irq = 0;
      write_port(16'h0008, 8'h20);
      write_port(16'h0000, 8'h20);
      repeat (4) @(posedge clk);
    end
  endtask
  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset_n = 1;

    // PC-98 cascade is slave INT -> master IRQ7. The machine programs the
    // master with ICW4 = 0x1D (SFNM = 1, buffered, master) and the slave with
    // 0x09 (BANK4@0x4BB1-0x4BC3); the old bench used 0x01, which has SFNM = 0,
    // so it could only ever pass a non-SFNM model.
    init_pic(16'h0000, 16'h0002, 8'h08, 8'h80, 8'h1D, 8'h7F);
    init_pic(16'h0008, 16'h000A, 8'h10, 8'h07, 8'h01, 8'hFD);
    if (!dut.master.icw4_sfnm) begin
      $display("FAIL master ICW4 0x1D did not set SFNM");
      errors = errors + 1;
    end

    @(negedge clk);
    slave_irq[1] = 1;
    repeat (8) @(posedge clk);
    if (!cpu_intr) begin
      $display("FAIL slave IRQ9 did not reach CPU");
      errors = errors + 1;
    end

    inta_cycle(); // first x86 INTA cycle is a dummy acknowledge

    @(negedge clk);
    cpu_inta = 1;
    while (!cpu_inta_ready) @(negedge clk);
    #1;
    if (cpu_inta_din[7:0] !== 8'h11) begin
      $display("FAIL cascade vector %02x", cpu_inta_din[7:0]);
      errors = errors + 1;
    end
    @(negedge clk);
    cpu_inta = 0;
    slave_irq[1] = 0;
    repeat (4) @(posedge clk);
    if (cpu_intr) begin
      $display("FAIL interrupt remained asserted after cascade INTA");
      errors = errors + 1;
    end

    // EOI both controllers in slave-then-master order.
    write_port(16'h0008, 8'h20);
    write_port(16'h0000, 8'h20);

    // ---- SFNM: a second slave request must be forwarded while the cascade is
    // in service. The authentic disk ISR omits the master EOI while another
    // slave request is in service and relies on the master's SFNM exemption
    // (BANK3@0xF9A5C-0xF9A6C). Without SFNM the master's own isr[7] blocks the
    // cascade until its EOI.
    @(negedge clk);
    slave_irq[1] = 1;                 // IRQ9 latches the slave and the cascade line
    repeat (8) @(posedge clk);
    // Both INTA pulses: the first is the x86 dummy cycle, the second transfers the vector
    // and sets the in-service bit on both controllers. With one pulse nothing enters
    // service, which made the check below vacuous.
    inta_cycle();
    inta_cycle();
    @(negedge clk);
    slave_irq[1] = 0;
    repeat (8) @(posedge clk);
    if (cpu_intr) begin
      $display("FAIL INT stayed high after the cascade was serviced");
      errors = errors + 1;
    end

    // ---- SFNM. The authentic disk ISR EOIs the slave and omits the master EOI while
    // another slave request is in service, relying on the master's special fully nested
    // mode to forward the cascade line past its own in-service IRQ7
    // (BANK3@0xF9A5C-0xF9A6C). So: EOI the SLAVE only, leave master isr[7] set, raise the
    // same line again, and require INT. Without the exemption the master blocks it, and
    // raising a higher-priority line instead -- IRQ8 -- passed either way, which is why
    // this check used to be inert.
    write_port(16'h0008, 8'h20);      // slave EOI only
    repeat (4) @(posedge clk);
    @(negedge clk);
    slave_irq[1] = 1;
    repeat (12) @(posedge clk);
    if (!cpu_intr) begin
      $display("FAIL SFNM did not forward a second slave request");
      errors = errors + 1;
    end
    slave_irq[1] = 0;
    inta_cycle();
    write_port(16'h0008, 8'h20);
    write_port(16'h0000, 8'h20);
    write_port(16'h0008, 8'h20);
    write_port(16'h0000, 8'h20);
    // ---- Every line's vector ----------------------------------------------
    // The master/slave pair is programmed with bases 0x08 and 0x10; every line must
    // answer with its own vector. Before this, 11 of the 16 lines had no test.
    //
    // Re-initialise first: the SFNM test above EOIs the slave only, so the master's
    // cascade bit is still in service, and an in-service bit blocks every
    // lower-priority line. A reset clears the pair AND the INTA bridge, whose state
    // machine acknowledges across two INTA assertions -- leaving it mid-acknowledge
    // would make the parity of every later pulse wrong. Then re-program the firmware's
    // own ICW values.
    reset_n = 0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset_n = 1;
    repeat (4) @(posedge clk);
    init_pic(16'h0000, 16'h0002, 8'h08, 8'h80, 8'h1D, 8'h7F);
    init_pic(16'h0008, 16'h000A, 8'h10, 8'h07, 8'h01, 8'hFD);
    for (integer line = 1; line <= 6; line = line + 1)
      check_line(line, 8'h08 + line[7:0]);
    for (integer line = 8; line <= 15; line = line + 1)
      check_line(line, 8'h10 + (line[7:0] - 8'd8));

    // IRQ0 comes from this module's own PIT: program channel 0 with a two-tick
    // divisor and let it expire.
    write_port(16'h0002, 8'hFE);
    write_port(16'h0077, 8'h36);
    write_port(16'h0071, 8'h02);
    repeat (200) @(posedge clk);
    if (!cpu_intr) begin
      $display("FAIL IRQ0 (PIT terminal count) did not assert INT");
      errors = errors + 1;
    end
    inta_cycle();
    inta_cycle();
    if (cpu_inta_din[7:0] !== 8'h08) begin
      $display("FAIL IRQ0 vector %02x, want 08", cpu_inta_din[7:0]);
      errors = errors + 1;
    end
    write_port(16'h0000, 8'h20);

    // ---- the acknowledge must not split the vector from the ISR ------
    // The capture this pins was VEC=14 (the slave's IRQ12) with the MASTER's
    // ISR=0x01: the delivered vector named one IRQ while the master put another in
    // service. Reproduce the shape: the slave's IRQ12 is the outstanding request, so
    // the published vector is the slave's 0x14, and a higher-priority MASTER request
    // (the keyboard, IRQ1) arrives in the window between that vector being published
    // and the acknowledge edge. The IRQ the returned vector names must be the IRQ the
    // master's ISR marks in service. Before the fix the vector was captured one cycle
    // before the ISR was set, so the vector read 0x14 while the ISR read 0x02.
    reset_n = 0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset_n = 1;
    repeat (4) @(posedge clk);
    init_pic(16'h0000, 16'h0002, 8'h08, 8'h80, 8'h1D, 8'h7D);  // master: IRQ1 + cascade
    init_pic(16'h0008, 16'h000A, 8'h10, 8'h07, 8'h01, 8'hEF);  // slave: IRQ12
    @(negedge clk);
    slave_irq[4] = 1;
    repeat (8) @(posedge clk);
    if (!cpu_intr) begin
      $display("FAIL IRQ12 did not reach INT before the ack-race case");
      errors = errors + 1;
    end
    inta_cycle();                                       // dummy first INTA cycle
    @(negedge clk);
    cpu_inta = 1;
    keyboard_irq = 1;                                   // the race: IRQ1 in the window
    while (!cpu_inta_ready) @(negedge clk);
    race_vec = cpu_inta_din[7:0];
    @(negedge clk);
    cpu_inta = 0;
    repeat (4) @(posedge clk);
    if (race_vec >= 8'h10) begin
      // A slave vector: the master must have put the cascade (IRQ7) in service.
      if (dbg_isr !== 8'h80) begin
        $display("FAIL ack-race: vector %02x names the slave but the master ISR is %02x ",
                 race_vec, dbg_isr);
        errors = errors + 1;
      end
    end else if (dbg_isr !== (8'h01 << race_vec[2:0])) begin
      $display("FAIL ack-race: vector %02x names IRQ%0d but the master ISR is %02x",
               race_vec, race_vec[2:0], dbg_isr);
      errors = errors + 1;
    end
    keyboard_irq = 0;
    slave_irq[4] = 0;
    reset_n = 0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset_n = 1;
    repeat (4) @(posedge clk);

    // ---- interrupts.md F1: a master-level SPURIOUS INTA after a prior cascade ack ----
    // The vector source was muxed on the frozen int_acked_irq, so once any cascade
    // ack had happened (int_acked_irq == 7), a spurious ack answered the SLAVE's parked
    // spurious vector 0x17 - the CPU landed in IVT[0x17], the IRQ15/calendar slot, and
    // that handler's EOI corrupted the in-service priority state. The 8259 convention
    // is icw2_vec|7 PER CHIP: 0x0F for a master spurious, 0x17 only when the cascade
    // acks an empty slave. FAIL-FIRST: the old mux answers 0x17 here.
    init_pic(16'h0000, 16'h0002, 8'h08, 8'h80, 8'h1D, 8'h7D);  // master: IRQ1 + cascade
    init_pic(16'h0008, 16'h000A, 8'h10, 8'h07, 8'h01, 8'hEF);  // slave: IRQ12
    // (1) a REAL cascade ack, so the previous acknowledge names master IRQ7
    @(negedge clk);
    slave_irq[4] = 1;
    repeat (8) @(posedge clk);
    inta_cycle();
    inta_cycle();
    if (cpu_inta_din[7:0] !== 8'h14) begin
      $display("FAIL F1 setup: cascade vector %02x, want 14", cpu_inta_din[7:0]);
      errors = errors + 1;
    end
    slave_irq[4] = 0;
    write_port(16'h0008, 8'h20);
    write_port(16'h0000, 8'h20);
    repeat (4) @(posedge clk);
    // (2) raise a MASTER request, then withdraw it (IMR write) before the handshake
    // runs - the classic cli/sti + mask shape that reaches INTA with nothing pending.
    @(negedge clk);
    keyboard_irq = 1;
    repeat (8) @(posedge clk);
    if (!cpu_intr) begin
      $display("FAIL F1: IRQ1 did not assert INT");
      errors = errors + 1;
    end
    keyboard_irq = 0;
    write_port(16'h0002, 8'hFF);          // the request is gone at the acknowledge
    repeat (4) @(posedge clk);
    // (3) the CPU already latched intr and takes its INTA pair anyway: the vector must
    // be the MASTER's own spurious 0x0F, not the previous ack's slave 0x17.
    inta_cycle();
    inta_cycle();
    if (cpu_inta_din[7:0] !== 8'h0F) begin
      $display("FAIL F1: spurious master INTA answered %02x, want 0F", cpu_inta_din[7:0]);
      errors = errors + 1;
    end
    reset_n = 0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset_n = 1;
    repeat (4) @(posedge clk);
  // ==== VERDICT ====

    if (errors == 0) begin
        $display("TB_PC9821_INTERRUPTS: PASS");
        $finish;
    end
    else $fatal(1, "TB_PC9821_INTERRUPTS: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog. The runner also bounds wall time
  // (BENCH_TIMEOUT) and greps the PASS marker, but a bench that
  // blocks on a DUT signal with no bound would hang CI forever.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_INTERRUPTS: TIMEOUT");
  end

endmodule
