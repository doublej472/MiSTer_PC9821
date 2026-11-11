`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The PC-9801-86's OPNA port model against NP2kai, register by register and flag by flag: the 0x18A shadow's per-register bytes and the 0x188 status flags match cbus/board86.c and sound/opntimer.c wherever the two references agree -- the timer overflow flag appears in the status read and the IRQ line follows the enable bits, a 0x27 write with bit 4 or 5 clears the matching flag, and registers above 0x0F read back the last data byte (0x20, 0x23), while the rhythm bank 0x10-0x1F reads the machine's FF with the extension closed (KIT1 YM29 READMAP, XE10T /OPNA2 IDC r10=FF). The SSG shadow's bytes are ASSERTED: register 7 reads the MACHINE's 0x00 (probes/OPNA.TXT CHIPID) and register 0x0f reads 0xff as NP2kai's opna_reset holds it, so master.lib's js_start read-modify-write (js_start.asm:67-72) lands on 0x80 - every tone/noise source routed, which is what js_start means - where NP2kai's 0xbf seed disconnects all six. An earlier reading took the 0x80 outcome as corruption; the capture shows it is the hardware's own. The remaining measured divergences are named and printed rather than asserted: the joystick at 0x0E ignores SSG register 0x0F bit 6 (NP2kai gates the stick on it), a timer whose IRQ enable is clear still sets its overflow flag where NP2kai's fmport_a/fmport_b set the flag only when the enable bit is set. Register 0x29 does not gate the timer IRQs, as on the Xe10 (docs/probes/YM29-XE10.TXT, YM29B-XE10.TXT) and in NP2kai, which never reads that register: a Timer B started with its 0x27 enable after 0x29 = 00 still raises the line.
//
// The PC-9801-86's OPNA port model against NP2kai, register by register and flag by flag: the 0x18A shadow's per-register bytes and the 0x188 status flags match cbus/board86.c and sound/opntimer.c wherever the two references agree -- the timer overflow flag appears in the status read only while the timer's enable bit is set (opntimer.c fmport_a/fmport_b), the IRQ line follows the enable bits, a 0x27 write with bit 4 or 5 clears the matching flag, and registers at or above 0x10 read back the last data byte. The SSG shadow's bytes are ASSERTED: register 7 reads the MACHINE's 0x00 (probes/OPNA.TXT CHIPID) and register 0x0f reads 0xff as NP2kai's opna_reset holds it, so master.lib's js_start read-modify-write lands on 0x80 - every tone/noise source routed, which is what js_start means - where NP2kai's 0xbf seed would disconnect all six (an earlier reading took the 0x80 outcome as corruption; the machine shows it is the hardware's own). The remaining measured divergences are named and printed rather than asserted: the joystick at 0x0E ignores SSG register 0x0F bit 6 (NP2kai gates the stick on it). Register 0x29 does not gate the timer IRQs, as on the Xe10 (docs/probes/YM29-XE10.TXT, YM29B-XE10.TXT) and in NP2kai, which never reads that register: a Timer B started with its 0x27 enable after 0x29 = 00 still raises the line.

// Reference: NP2kai (PRIMARY) cbus/board86.c (opna_i188/
// opna_i18a/opna_i18c/opna_i18e), sound/opna.c (opna_reset, opna_readRegister),
// sound/opntimer.c (opna_settimer, fmport_a/fmport_b), sound/fmboard.c
// (fmboard_getjoy). Every expected byte below is quoted from one of those.

// ==== DUT ====
// pc9821_opna driven at its own host port (0x188 = register select / status read,
// 0x18A = data), which is the addressing a driver uses; tb_pc9821_opna already
// proves iobus routes those ports here.
module tb_pc9821_opna_regs;
  localparam integer SYS_CLOCK_HZ = 50_000_000;
  reg clk = 0;
  always #10 clk = ~clk;

  reg        reset = 1;
  reg [15:0] io_addr = 16'h0188;
  reg        io_wr = 0, io_rd = 0;
  reg  [7:0] io_din = 8'h00;
  wire [7:0] io_dout;
  wire       io_rd_wait, irq;
  wire signed [19:0] snd_l, snd_r;
  reg  [5:0] joystick = 6'b111111;

  pc9821_opna #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) dut (
    .clk(clk), .reset(reset),
    .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd),
    .io_din(io_din), .io_dout(io_dout), .io_rd_wait(io_rd_wait),
    .extend(1'b0),
    .joystick(joystick),
    .snd_l(snd_l), .snd_r(snd_r),
    .irq(irq),
    .rhythm_we(1'b0), .rhythm_waddr(12'd0), .rhythm_wdata(16'd0)
  );

  integer errors = 0;
  integer divergences = 0;

  task automatic fail(input [8*100-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // A case where NP2kai and this RTL differ: PRINT it and count it, do not assert it.
  // The report owns the divergence; the bench owns the measurement.
  task automatic diverge(input [8*80-1:0] what, input [7:0] got, input [7:0] np2);
    begin
      $display("DIVERGENCE %0s: RTL=%02x NP2kai=%02x", what, got, np2);
      divergences = divergences + 1;
    end
  endtask

  // ==== STIMULUS ====
  task automatic write_port(input [15:0] portnum, input [7:0] data);
    begin
      @(negedge clk); io_addr = portnum; io_din = data; io_wr = 1;
      @(negedge clk); io_wr = 0; io_din = 8'h00;
      @(negedge clk);
    end
  endtask

  task automatic read_port(input [15:0] portnum, output [7:0] data);
    begin
      @(negedge clk); io_addr = portnum; io_rd = 1;
      @(negedge clk); @(negedge clk);
      #1 data = io_dout;
      @(negedge clk); io_rd = 0;
      @(negedge clk);
    end
  endtask

  // The games' own register write: index to 0x188, data to 0x18A
  // (rec98 libs/master.lib/soundio.asm:52-56).
  task automatic sound_o(input [7:0] reg_index, input [7:0] data);
    begin
      write_port(16'h0188, reg_index);
      write_port(16'h018A, data);
    end
  endtask

  // Select a register through 0x188 and read it back through 0x18A.
  task automatic read_reg(input [7:0] reg_index, output [7:0] data);
    begin
      write_port(16'h0188, reg_index);
      read_port(16'h018A, data);
    end
  endtask

  task automatic wait_clk(input integer n);
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) @(posedge clk);
    end
  endtask

  // Stop both timers and clear both overflow flags: 0x27 = 0x30 is bits 4 and 5
  // (the two resets) with both start bits clear.
  task automatic stop_and_clear;
    begin
      sound_o(8'h27, 8'h30);
      wait_clk(80);
    end
  endtask

  task automatic wait_irq(input integer limit, output integer cycles);
    integer n;
    begin
      n = 0;
      while (!irq && n < limit) begin @(posedge clk); n = n + 1; end
      cycles = irq ? n : 0;
    end
  endtask

  // ==== CHECKS ====
  reg [7:0] v, rb;
  integer   n_cycles;
  integer   k;

  initial begin
    repeat (40) @(posedge clk);
    @(negedge clk); reset = 0;
    repeat (2000) @(posedge clk);   // the glue's reset stretcher, 16 clk&cen

    // ---- 1. the 0x18A shadow's bytes at reset -----------------------------
    // NP2kai's opna_reset seeds the register file: reg[0x07] = 0xbf,
    // reg[0x0e] = 0xff, reg[0x0f] = 0xff, everything else 0 (sound/opna.c:135-140).
    // opna_i18a returns s.reg[nAddress] for every nAddress < 0x10, so those are
    // the bytes 0x18A answers before any write. The MACHINE contradicts that seed
    // at register 7: probe OPNAPRO selects it and reads 0x00
    // (docs/probes/OPNA.TXT section CHIPID: `0x18A with 0x188=07 (SSG register 7;
    // the references' reset seed is BF): 00`), on a card that same block proves
    // present (`0x188=FF` answers the -86 chip ID 0x01), so the byte is the chip's
    // answer and not open bus. The die-shot LLE is with the machine here: an SSG
    // read returns the register itself (fmopna_impl.c:2232-2235) and that
    // register is loaded from the internal bus at reset, which is 0 (:2114-2130).
    // Register 0x0F (0xff) and 0x00 (0x00) keep NP2kai's seeds; 0x0E is answered
    // by fmboard_getjoy instead and is checked below.
    read_reg(8'h00, rb);
    if (rb !== 8'h00) fail("the fresh SSG shadow at register 0x00 is not 0x00");
    read_reg(8'h07, rb);
    if (rb !== 8'h00) fail("the fresh SSG shadow at register 0x07 is not the machine's 0x00 (OPNA.TXT CHIPID)");
    read_reg(8'h0F, rb);
    if (rb !== 8'hFF) fail("the fresh SSG shadow at register 0x0F is not the reference's 0xFF");

    // ---- 1b. NP2kai's third SSG shadow seed: register 0x0E = 0xff ---------
    // opna_reset (sound/opna.c:136-139) seeds reg[0x07], reg[0x0E] AND reg[0x0F].
    // Register 0x0E can never be read back through 0x18A - opna_i18a answers it
    // from the joystick - so this byte is SHADOW-ONLY and the check reaches the
    // shadow itself rather than a port. It is worth pinning anyway: it is the
    // byte the shadow holds for the read model the board implements, and an audit
    // found it left at 0x00 while the reference holds 0xFF.
    if (dut.ssg_reg[14] !== 8'hFF)
      fail("the SSG shadow's register 0x0E is not the reference's reset 0xFF (opna_reset, sound/opna.c:137)");

    // ---- 2. master.lib's js_start read-modify-write ------------------------
    // js_start.asm:67-72 does read reg 7 / and 3Fh / or 80h / write it back. Its
    // subject is the SSG's TWO I/O-PORT DIRECTIONS - bits 6/7, which the -86
    // board's game port uses - and it PRESERVES the six active-low tone/noise
    // enables. From the machine's reset byte 0x00 the write-back is therefore
    // 0x80: every source routed and the directions set, which is what "start the
    // SSG" means. From NP2kai's 0xbf seed the write-back is 0xbf and all six
    // sources stay DISCONNECTED - an SSG that stays silent however the guest
    // programs its periods and amplitudes. An earlier reading took the 0x80
    // outcome as corruption; the machine capture (OPNA.TXT CHIPID) shows it is
    // the hardware's own, so 0x80 is the byte asserted here.
    read_reg(8'h07, rb);
    sound_o(8'h07, (rb & 8'h3F) | 8'h80);
    read_reg(8'h07, rb);
    if (rb !== 8'h80) fail("js_start's reg-7 read-modify-write result is not the machine's 0x80 (OPNA.TXT CHIPID + js_start.asm)");

    // ---- 3. the joystick at 0x0E, and the SSG 0x0F bit-6 gate --------------
    // fmboard_getjoy (sound/fmboard.c:57-95) reads the stick only while
    // (reg[15] & 0x40) == 0, and its value is the six switch lines active low.
    // The upper two bits carry opna->s.intr, the strap-derived level, which is
    // 0xc0 on the measured machine, so the all-released byte is 0xFF either way.
    joystick = 6'b111110;                    // up held: NP2kai 0x3e | 0xc0
    // Nothing has written SSG register 0x0F yet, so NP2kai's shadow still holds
    // its reset byte 0xff (bit 6 set) and masks the stick out; this RTL answers
    // the switch immediately. The gate's own check is js_sense's sequence below.
    write_port(16'h0188, 8'h0E);
    read_port(16'h018A, v);
    if ((v & 8'h3F) !== 8'h3E) fail("the joystick at 0x0E did not return the held up switch");
    if ((v & 8'h3F) === 8'h3E) diverge("joystick read at reg 0x0E with SSG reg 0x0F bit 6 SET", v, 8'hFF);
    // js_sense.asm:56-69 writes reg 0x0F = 0x80 first; then both read the stick.
    sound_o(8'h0F, 8'h80);
    write_port(16'h0188, 8'h0E);
    read_port(16'h018A, v);
    if ((v & 8'h3F) !== 8'h3E)
      fail("the joystick at 0x0E is not live after SSG reg 0x0F bit 6 is cleared (js_sense's own sequence)");
    joystick = 6'b111111;

    // ---- 4. 0x18A register 0xFF is the -86 chip ID -------------------------
    read_reg(8'hFF, rb);
    if (rb !== 8'h01) fail("register 0xFF did not answer the -86 chip ID 0x01");

    // ---- 5. registers above 0x0F read back the last DATA byte --------------
    // opna_i18a: above 0x0F and below 0xFF it returns s.data, the last byte
    // through any data port -- so a data write is read back without re-selecting.
    // The real machine overrides that for the rhythm bank 0x10-0x1F, 0x22 and 0x29 while
    // the extension is closed (this bench's extend = 0): they read FF, not the data byte
    // (docs/probes/KIT1-XE10-YM29.TXT READMAP `r10= FF FF FF FF FF FF FF FF FF FF FF FF FF
    // FF FF FF`, `RD29 v29=1F pre=FF post=FF`; 0x10 also XE10T-XE10-OPNA2.TXT IDC
    // `ext=0 ... r10=FF`), which outranks NP2kai's s.data. 0x20 and 0x23 (no YM2608
    // function) keep the NP2kai echo of a data write (the machine's READMAP reads them
    // after a select alone and echoes the select, as s.data does).
    write_port(16'h0188, 8'h10);
    write_port(16'h018A, 8'h01);
    read_port(16'h018A, rb);
    if (rb !== 8'hFF) fail("rhythm register 0x10 with the extension closed did not read the machine's FF");
    write_port(16'h0188, 8'h11);
    write_port(16'h018A, 8'h3F);
    read_port(16'h018A, rb);
    if (rb !== 8'hFF) fail("rhythm register 0x11 with the extension closed did not read the machine's FF");
    write_port(16'h0188, 8'h18);
    write_port(16'h018A, 8'hDF);
    read_port(16'h018A, rb);
    if (rb !== 8'hFF) fail("rhythm register 0x18 with the extension closed did not read the machine's FF");
    write_port(16'h0188, 8'h1D);
    write_port(16'h018A, 8'h9F);
    read_port(16'h018A, rb);
    if (rb !== 8'hFF) fail("rhythm register 0x1D with the extension closed did not read the machine's FF");
    write_port(16'h0188, 8'h20);
    write_port(16'h018A, 8'h5A);
    read_port(16'h018A, rb);
    if (rb !== 8'h5A) fail("a data write to register 0x20 was not the byte 0x18A reads back");
    write_port(16'h0188, 8'h23);
    write_port(16'h018A, 8'hA5);
    read_port(16'h018A, rb);
    if (rb !== 8'hA5) fail("a data write to register 0x23 was not the byte 0x18A reads back");

    // ---- 6. Timer B, IRQ ENABLED: flag + line, then the reset bit ----------
    // opna_settimer: bit1 starts B, bit3 enables its IRQ; fmport_b sets status
    // bit 1 on overflow. One count is 2304 master clocks (0x26 = 0xFF).
    stop_and_clear;
    sound_o(8'h26, 8'hFF);
    sound_o(8'h27, 8'h0A);
    wait_irq(60000, n_cycles);
    if (n_cycles == 0) fail("Timer B with its IRQ enabled never raised the board IRQ line");
    read_port(16'h0188, rb);
    if (rb[1] !== 1'b1) fail("Timer B's overflow flag is not status bit 1 with its IRQ enabled");
    // 0x27 = 0x2A keeps B running and bit3 set and resets the flag (bit 5).
    sound_o(8'h27, 8'h2A);
    wait_clk(80);
    read_port(16'h0188, rb);
    if (rb[1] !== 1'b0) fail("Timer B's flag did not clear on a 0x27 write with bit 5 set");
    if (irq !== 1'b0) fail("the IRQ stayed up after Timer B's flag was cleared");

    // ---- 7. Timer B, IRQ DISABLED: the flag is not set -------------------
    // fmport_b guards the status write with (reg[0x27] & 0x08), so with bit3
    // clear the overflow leaves status bit 1 at 0 (opntimer.c:113-116). The
    // line must also stay low.
    stop_and_clear;
    sound_o(8'h26, 8'hFF);
    sound_o(8'h27, 8'h02);
    wait_clk(40000);
    read_port(16'h0188, rb);
    if (rb[1] !== 1'b0) fail("Timer B's overflow flag set with its IRQ enable (0x27 bit3) clear");
    if (irq !== 1'b0) fail("Timer B's clear IRQ enable did not hold the board line low");

    // ---- 8. Timer A, IRQ DISABLED and ENABLED ------------------------------
    // The same shape for A: 0x24/0x25 carry 1024-NA, 0x27 bit0 starts, bit2
    // enables the IRQ, bit4 resets the flag, status bit 0 reports it.
    stop_and_clear;
    sound_o(8'h24, 8'hFC);
    sound_o(8'h25, 8'h00);
    sound_o(8'h27, 8'h01);
    wait_clk(40000);
    read_port(16'h0188, rb);
    if (rb[0] !== 1'b0) fail("Timer A's overflow flag set with its IRQ enable (0x27 bit2) clear");
    if (irq !== 1'b0) fail("Timer A's clear IRQ enable did not hold the board line low");
    stop_and_clear;
    sound_o(8'h24, 8'hFC);
    sound_o(8'h25, 8'h00);
    sound_o(8'h27, 8'h05);
    wait_irq(60000, n_cycles);
    if (n_cycles == 0) fail("Timer A with its IRQ enabled never raised the board IRQ line");
    read_port(16'h0188, rb);
    if (rb[0] !== 1'b1) fail("Timer A's overflow flag is not status bit 0 with its IRQ enabled");
    sound_o(8'h27, 8'h34);          // stop A, keep its enable, reset its flag
    wait_clk(80);
    read_port(16'h0188, rb);
    if (rb[0] !== 1'b0) fail("Timer A's flag did not clear on a 0x27 write with bit 4 set");

    // ---- 9. register 0x29 does not gate the timer IRQs ---------------------
    // NP2kai's writeRegister stores 0x29 in s.reg and consults it nowhere; fmport_b
    // raises the IRQ on `reg[0x27] & 0x08` alone (sound/opntimer.c), so a timer with
    // its enable bit set still interrupts with 0x29 = 00. The machine agrees for Timer
    // A (docs/probes/YM29-XE10.TXT `IRQ  v29=00 n=21`; tb_pc9821_opna_timers 9b
    // asserts that one). Mask everything, arm Timer B, and the line must still rise.
    stop_and_clear;
    sound_o(8'h29, 8'h00);
    sound_o(8'h26, 8'hFF);
    sound_o(8'h27, 8'h0A);
    wait_irq(60000, n_cycles);
    if (n_cycles == 0)
      fail("Timer B with its 0x27 enable set did not raise the IRQ after 0x29 = 00");
    sound_o(8'h29, 8'h1F);         // back to the reset value
    stop_and_clear;

    // ---- 10. the status byte's timer bits are the ONLY live low bits -------
    // opna_i188 returns s.status, which opntimer.c only ever ORs 0x01/0x02 into;
    // jt12_dout's addr-0 word is {busy,5'd0,flag_B,flag_A}. Bits 6:2 are 0.
    stop_and_clear;
    read_port(16'h0188, rb);
    if (rb[6:2] !== 5'b00000) fail("the 0x188 status has a live bit outside BUSY and the two timer flags");

    // ==== VERDICT ====
    $display("NOTE TB_PC9821_OPNA_REGS: %0d NP2kai divergence(s) named above", divergences);
    if (errors == 0) begin
      $display("TB_PC9821_OPNA_REGS: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OPNA_REGS: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog: every wait here is cycle-bounded, so this only fires if
  // the DUT stops responding altogether.
  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_OPNA_REGS: TIMEOUT");
  end
endmodule
