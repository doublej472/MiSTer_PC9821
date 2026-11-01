// PC-9821 interrupt backbone: master/slave 8259A pair, PC-98 PIT, and the
// native two-cycle z486 INTA handshake. The slave cascades on master IRQ7.
// The slave's lines (IRQ8..IRQ15) are the system devices' and include IRQ13,
// the bus mouse's periodic request (NP2kai mouseint's pic_setirq(0x0d),
// io/mouseif.c:131-140): pc9821_system wires pc9821_mouse's pulse onto
// slave_irq[5], which reaches the slave's IR5 here.

`default_nettype none

module pc9821_interrupts #(
    parameter integer SYS_CLOCK_HZ = 50_000_000
) (
    input wire clk,
    input wire reset_n,

    input  wire        io_wr,
    input  wire        io_rd,
    // 16 bits because that is the host's I/O address bus, but only [2:1] is read: it is the
    // register index inside each device, and the three selects arrive separately (below).
    /* verilator lint_off UNUSEDSIGNAL */   // io_addr[15:3] and [0] have no reader, by design
    input  wire [15:0] io_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    // The three selects the host decoded for this block, so the same decode is
    // not written twice: pc9821_system owns it, in
    // pc9821_device_select.sv, and tb_pc9821_device_select.sv sweeps every
    // address against it. io_addr stays for the register index inside each
    // device (the PIT's addr[2:1] and the 8259s' A0).
    input  wire        master_cs,
    input  wire        slave_cs,
    input  wire        pit_cs,
    input  wire  [7:0] io_din,
    output wire  [7:0] io_dout,

    input wire keyboard_irq,
    input wire vsync_irq,
    input wire [3:0] master_aux_irq, // IRQ3..IRQ6
    input wire [7:0] slave_irq,      // system IRQ8..IRQ15 (bit 5 = IRQ13, the bus mouse)

    output wire        cpu_intr,
    input  wire        cpu_inta,
    output wire [31:0] cpu_inta_din,
    output wire        cpu_inta_ready,
    output wire        pit_out0,
    // PIT CHANNEL 1 is the BEEPER's tone generator; channel 2 is not. The authentic ITF's own
    // beep routine (BANK4@0x4B2B) writes control 0x76 -- bits 7:6 = 01, CHANNEL 1, LSB then MSB,
    // mode 3 -- and divisor 0x04CD (1229 -> 2.4576 MHz / 1229 = 2000 Hz) through the
    // 0x3FDF/0x3FDB PORT ALIAS, which is why a scan of 0x73/0x75 alone misses it. QEMU agrees
    // (hw/i386/pc98.c: "PIT channel 1, gated by active-low system-PPI port-C bit 3", pit-channel
    // 1) and NP2kai agrees (sound/beepc.c; io/pit.c calls beep_hzset from the CHANNEL 1 write and
    // labels 0x75 "// rs-232c"). Channel 2 was routed to the beeper in error and channel 1 tied
    // off, so the beep played whatever the RS-232C channel happened to hold.
    output wire        pit_out1,
    output wire        pit_out2,

    // Bring-up telemetry (master PIC, where IRQ1 is).
    output wire [7:0] dbg_imr,
    output wire [7:0] dbg_irr,
    output wire [7:0] dbg_isr,
    output wire [7:0] dbg_s_imr,
    output wire [7:0] dbg_s_isr
);

  // The 8253/8254 is visible twice: at 0x71/0x73/0x75/0x77 and at the odd ports
  // of 0x3FD9..0x3FDF. QEMU aliases register i at 0x71+i*2 and 0x3FD9+i*2
  // (i8254-pc98.c:472) and NP2kai binds 0x3FD9->ch0, 0x3FDB->ch1,
  // 0x3FDD->ch2, 0x3FDF->control (pit.c:539-545). linux-pc98 names the block
  // "beep freq." because the beep tone IS PIT channel 1 (the pit_out1 note above) -
  // this alias reaches it as 0x3FDB. The ITF never touches the beep: it runs
  // its TIMER self-test through the alias instead, writing the control port at
  // BANK4@0x4A6C/0x4B2D/0x51CE, the channel-1 count at 0x4A72/0x4B3F/0x51E2 and
  // reading 0x3FDB at BANK4@0x373, so an undecoded alias read 0xFF and the
  // self-test halted with "TIMER ERROR".
  //
  // The select arrives from pc9821_device_select; io_addr[2:1] is the register
  // index for both ranges (0x71->0, 0x77->3 and 0x3FD9->0, 0x3FDF->3).
  wire [1:0] pit_addr = io_addr[2:1];

  wire [7:0] master_dout, slave_dout, pit_dout;
  wire master_int, slave_int;
  wire [7:0] master_vec, slave_vec;
  wire [2:0] master_irq, slave_irq_num;
  wire [2:0] master_acked_irq, slave_acked_irq;
  wire master_acked_valid, slave_acked_valid;
  wire pic_ack;
  // The cascade ack is decided at the ACKNOWLEDGE EDGE, from the live highest-priority
  // request: the slave latches its own in-service bit on that same edge, so the master's
  // IRQ7-in-service, this pulse and the slave's ISR set all refer to one cycle of `highest`.
  wire cascade_ack = pic_ack && (master_irq == 3'd7);
  // The vector, by contrast, is muxed from the ACKED IRQ (int_acked_irq), not the live
  // highest. int_vec is latched to the acked IRQ at the ack edge, so picking with the live
  // highest could name the slave while the vector value is the master's. AND IT IS QUALIFIED
  // BY THE ACK EVENT'S OWN VALIDITY: after a prior cascade ack a master-level SPURIOUS
  // ack (inta with nothing to serve) left int_acked_irq frozen at 7 and this mux answered
  // the slave's parked spurious vector 0x17 where the 8259 convention is the MASTER's own
  // icw2_vec|7 = 0x0F. int_acked_valid is latched at the ack edge,
  // so a spurious ack selects master_vec (which the PIC parks at icw2_vec|7 on that same
  // edge) and only a real cascade ack selects the slave - whose own spurious answer, 0x17,
  // is exactly the slave-side convention when the cascade fires with the slave idle.
  wire [7:0] selected_vector = (master_acked_valid && (master_acked_irq == 3'd7)) ? slave_vec :
                                                                  master_vec;

  assign io_dout = master_cs ? master_dout :
                   slave_cs  ? slave_dout  :
                   pit_cs    ? pit_dout    : 8'hFF;

  // WD_UNMASKED bit 1: the keyboard's acking 0x41 read withdraws a latched IRQ1
  // even unmasked, so a polled read cannot leave a phantom INT 09h behind.
  // WD_UNMASKED bit 0: the PIT's OUT0 falling (a channel-0 reprogram to mode 0, or a
  // mode-0 count write) withdraws an unacknowledged IRQ0 whether masked or not -
  // NP2kai clears master IRR0 on every channel-0 count and mode-set write
  // (io/pit.c pit_o71 `pic.pi[0].irr &= (~1);`, pit_o77 `if (chnum == 0)`), and the
  // Xe10's IRR follows OUT0 (docs/probes/IRQWD.TXT; the IMR sits after the IRR).
  // Without it Might and Magic III's timer re-arm looped on a phantom IRQ0
  // (tb_pc9821_pit_irq_reprogram).
  pc9821_pic #(.BASE_VEC(8'h08), .CASCADE_IRQ(7), .WD_MASK(8'h03),
               .WD_UNMASKED(8'h03)) master (
      .clk(clk), .rst_n(reset_n), .cs(master_cs), .wr(io_wr), .rd(io_rd),
      .a0(io_addr[1]), .din(io_din), .dout(master_dout),
      .ir_in({slave_int, master_aux_irq, vsync_irq, keyboard_irq, pit_out0}),
      .int_out(master_int), .int_vec(master_vec), .int_irq(master_irq),
      .int_acked_irq(master_acked_irq), .int_acked_valid(master_acked_valid),
      .inta(pic_ack),
      .dbg_imr(dbg_imr), .dbg_irr(dbg_irr), .dbg_isr(dbg_isr)
  );

  pc9821_pic #(.BASE_VEC(8'h10), .WD_MASK(8'h02)) slave (
      .clk(clk), .rst_n(reset_n), .cs(slave_cs), .wr(io_wr), .rd(io_rd),
      .a0(io_addr[1]), .din(io_din), .dout(slave_dout), .ir_in(slave_irq),
      .int_out(slave_int), .int_vec(slave_vec), .int_irq(slave_irq_num),
      .int_acked_irq(slave_acked_irq), .int_acked_valid(slave_acked_valid),
      .inta(cascade_ack),
      // The slave's register state is CONNECTED BUT NOT REPORTED. The telemetry message is a
      // fixed 299-byte contract (tools/decode_telemetry.py, tools/check_telemetry_contract.py)
      // carrying ONE IMR/IRR/ISR set, and this pair reports the MASTER's - so adding the
      // slave's would change the contract in three files at once. They are wired here rather
      // than left missing because a port connected to nothing is a floating condition a
      // reader cannot distinguish from an oversight, and because IRQ12 (the sound IRQ) and
      // the other system lines live on this PIC: if a future capture needs the
      // slave's mask, the wire is already there. Consumed below so nothing is undriven.
      .dbg_imr(slave_dbg_imr), .dbg_irr(slave_dbg_irr), .dbg_isr(slave_dbg_isr)
  );

  pc9821_pit #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) pit (
      .clk(clk), .rst_n(reset_n), .cs(pit_cs), .addr(pit_addr),
      .wr(io_wr), .rd(io_rd), .din(io_din), .dout(pit_dout),
      .out0(pit_out0), .out1(pit_out1), .out2(pit_out2)
  );

  pc9821_inta_bridge inta_bridge (
      .clk(clk), .reset_n(reset_n), .pic_interrupt_do(master_int),
      .pic_interrupt_vector(selected_vector), .pic_interrupt_done(pic_ack),
      .cpu_intr(cpu_intr), .cpu_inta(cpu_inta),
      .cpu_inta_din(cpu_inta_din), .cpu_inta_ready(cpu_inta_ready)
  );

  wire [7:0] slave_dbg_imr, slave_dbg_irr, slave_dbg_isr;
  assign dbg_s_imr = slave_dbg_imr;
  assign dbg_s_isr = slave_dbg_isr;

  // Keeps the slave PIC's debug outputs - and slave_irq_num / slave_acked_irq /
  // slave_acked_valid, the slave's in-service and last-acked IRQ numbers - from being
  // undriven or unused.
  // The 1'b0 makes the AND constant, so this synthesises to nothing; it is a named
  // consumer, not logic.
  /* verilator lint_off UNUSEDSIGNAL */   // consumed on purpose: see the note on `slave`
  wire _unused_ok = &{1'b0, slave_irq_num, slave_acked_irq, slave_acked_valid,
                      slave_dbg_imr, slave_dbg_irr, slave_dbg_isr};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
