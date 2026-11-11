// Two device interrupt lines on ONE 8259 input: the PC-9801-86 board's INT5 strap (IRQ12),
// which carries both the OPNA's timer interrupt and the 86-PCM's buffer interrupt
// (pc9821_system.sv, the `.slave_irq` bit 4 wiring).
//
// WHY NOT A PLAIN OR. The 8259 latches a request on a RISING edge (pc9821_pic.sv
// `ir_set = ir_in & ~ir_prev`). With the two lines ORed, an event from one source while the
// other already holds the line makes no edge, so the event is never requested. The 86-PCM's
// line is a level that stays high while its interrupt is enabled (0xA468 bit 5) and the buffer
// is at or below the 0xA46A threshold (pc9821_pcm86's irq_query), which includes an enabled,
// EMPTY buffer: a program that leaves 0xA468 bit 5 set (Riql's PCM driver: 0xA468 = 0xB1) is
// followed after a software reboot by one that never clears it (Metajo SP's PCML writes 0xA468
// read-modify-write: 0xB9, 0xA1, 0xA3 in NP2kai's trace of the same sequence), and every OPNA
// timer interrupt its FM driver PCP waits on is then lost: the screen stays black after the
// first logo (the kit-2 core runs). The real PC-9821Xe10 runs that sequence (Riql, then Metajo SP)
// through Metajo's intro to its title menu (docs/probes/KIT2-XE10-RUNLOG.TXT steps 06 and 07,
// docs/user/compatibility.md's Metajo SP entry), so on the machine those timer interrupts arrive.
//
// THE RULE: every event from either source is its own request, as NP2kai delivers them - each
// OPNA timer event raises the shared IRQ by itself (sound/opntimer.c fmport_a/fmport_b:
// `if ((intreq) && (opna->s.irq != 0xff)) pic_setirq(opna->s.irq);`, with intreq true when
// the timer's flag newly sets) and so does each 86-PCM event (sound/pcm86c.c pcm86_cb:
// `pic_setirq(pcm86->irq);`), whatever the other source is doing. An event here is a
// source's rising edge. When it comes while the OTHER source already holds the line, the line
// is dropped for exactly one cycle after it (the producer's own bubble, SCED R6, the same shape
// as pc9821_pcm86's irq_bubble), so the PIC sees a fresh rising edge. An event from a low line
// (the other source low) passes unchanged, with no added cycle; two events in one cycle are
// one rising edge, as two pic_setirq calls before an acknowledge are one request.
//
// The bubble is a falling edge on a line the slave PIC withdraws on (WD_UNMASKED bit 4,
// pc9821_interrupts.sv): a request already latched and not yet acknowledged is withdrawn for
// the one cycle and latched again by the rising edge that follows, exactly as pc9821_pcm86's
// own bubble does on the same line.
`default_nettype none

module pc9821_irq_share (
    input  wire clk,
    input  wire reset,
    input  wire irq_a,      // the OPNA's timer interrupt line
    input  wire irq_b,      // the 86-PCM's interrupt line
    output wire irq         // to the 8259 input
);

  reg a_q, b_q;             // each source's line one cycle ago
  reg bubble;               // the one cycle the shared line is dropped

  // An event is a source's rising edge; it needs the bubble only when the other source held
  // the line in the cycle before (the shared line was already high, so it made no edge).
  wire a_event = irq_a & ~a_q;
  wire b_event = irq_b & ~b_q;
  wire hidden  = (a_event & b_q) | (b_event & a_q);

  always @(posedge clk) begin
    if (reset) begin
      a_q    <= 1'b0;
      b_q    <= 1'b0;
      bubble <= 1'b0;
    end else begin
      a_q    <= irq_a;
      b_q    <= irq_b;
      bubble <= hidden;
    end
  end

  assign irq = (irq_a | irq_b) & ~bubble;

`ifndef SYNTHESIS
  // The contract (SCED R8): a bubble only ever follows a cycle in which the shared line was
  // already high (else the event made its own edge and dropping the line would delay it).
  reg line_q;
  always @(posedge clk) begin
    line_q <= reset ? 1'b0 : (irq_a | irq_b);
    if (!reset && bubble && !line_q)
      $fatal(1, "pc9821_irq_share: bubble after a cycle in which the shared line was low");
  end
`endif

endmodule

`default_nettype wire
