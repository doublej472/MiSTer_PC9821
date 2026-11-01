// PIC INTA Bridge: PC-9821 PIC handshake to z486 INTA bus cycles
//
// ao486 PIC uses: interrupt_do (request), interrupt_vector (8-bit), interrupt_done (ack)
// z486 uses: intr (level input), inta (2-cycle bus sequence), din (vector on 2nd INTA)
//
// Protocol:
//   PIC.interrupt_do to z486.intr
//   z486.inta (1st cycle) to dummy response (ready + din=0)
//   z486.inta (2nd cycle) to return interrupt_vector, pulse interrupt_done
//
`timescale 1ns/1ns

`default_nettype none

module pc9821_inta_bridge (
    input              clk,
    input              reset_n,

    // PIC interface
    input              pic_interrupt_do,       // PIC has pending interrupt
    input       [7:0]  pic_interrupt_vector,   // Interrupt vector number
    output reg         pic_interrupt_done,     // Acknowledge to PIC

    // z486 interface
    output reg         cpu_intr,               // Interrupt request to CPU
    input              cpu_inta,               // INTA bus cycle from CPU
    output reg [31:0]  cpu_inta_din,           // Data to CPU during INTA
    output reg         cpu_inta_ready          // Ready signal during INTA
);

// State machine
localparam S_IDLE  = 3'd0;
localparam S_INTA1 = 3'd1;  // First INTA cycle (dummy)
localparam S_INTA2 = 3'd2;  // Second INTA cycle: acknowledge the PIC
localparam S_ACK   = 3'd3;  // one cycle for the PIC to latch the acked IRQ
localparam S_XFER  = 3'd4;  // hand the CPU the vector the acked IRQ names

reg [2:0] state;
reg inta_responded;  // Guard against double-fire (BIU holds inta for 2 posedges)

// The two states whose arm answers the CPU: the first INTA's dummy response (S_IDLE) and
// the second INTA's PIC acknowledge (S_INTA2). `cpu_inta` is a LEVEL - z486 holds it until
// this bridge's ready, and its external valid clears on the accept edge
// (src/z486/bus_unit.sv:348-350 `ext_valid_r <= 1'b0`), so the CPU
// releases the strobe for exactly one cycle between the two INTA bus cycles and may
// re-present on the next. One answer per asserted strobe is what the flag below counts.
wire inta_gate    = (state == S_IDLE) || (state == S_INTA2);
wire inta_present = cpu_inta && inta_gate;
wire inta_arm     = inta_present && !inta_responded;   // the answer, taken this cycle

always @(posedge clk) begin
    if (!reset_n) begin
        state <= S_IDLE;
        cpu_intr <= 1'b0;
        pic_interrupt_done <= 1'b0;
        cpu_inta_ready <= 1'b0;
        cpu_inta_din <= 32'h0;
        inta_responded <= 1'b0;
    end else begin
        // Default: deassert one-cycle signals
        pic_interrupt_done <= 1'b0;
        cpu_inta_ready <= 1'b0;

        // Forward PIC interrupt request to CPU
        // (cleared when interrupt_done pulses)
        cpu_intr <= pic_interrupt_do;

        case (state)
            S_IDLE: begin
                if (inta_arm) begin
                    // First INTA cycle: acknowledge bus handshake but don't
                    // assert resp_valid - no data for OPR_R on this cycle.
                    cpu_inta_din <= 32'h0;
                    cpu_inta_ready <= 1'b1;
                    state <= S_INTA1;
                end
            end

            // One cycle only, and UNCONDITIONAL: this state must not leave by observing a
            // level drop (docs/single-cycle-event-discipline.md R6). What the sequence
            // needs - a release between the two INTA bus cycles - is enforced by the taken
            // flag, not by this wait: the flag is cleared only while cpu_inta is LOW, so
            // S_INTA2's acknowledge is unreachable until a real release has been seen,
            // whether or not this state was still around to watch it.
            S_INTA1: state <= S_INTA2;

            S_INTA2: begin
                if (inta_arm) begin
                    // Second INTA cycle: acknowledge the PIC. The PIC latches the
                    // acked IRQ and its vector at the edge that ends this state;
                    // the transfer below reads that one latched value, so the vector
                    // the CPU gets cannot name a different IRQ than the one the PIC
                    // put in service. Capturing the vector on this edge while the PIC
                    // set the ISR a cycle later is what split them.
                    pic_interrupt_done <= 1'b1;
                    state <= S_ACK;
                end
            end

            S_ACK: begin
                // The acknowledge pulse is high this cycle. Wait one cycle so the PIC
                // has latched int_vec/int_acked_irq off the same edge, then transfer.
                state <= S_XFER;
            end

            S_XFER: begin
                // Second INTA cycle: return the vector the acked IRQ names.
                cpu_inta_din <= {24'h0, pic_interrupt_vector};
                cpu_inta_ready <= 1'b1;
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase

        // The taken flag's ONE next-state expression (R2): set by an answer, held for as
        // long as the strobe is asserted, cleared by the release. One expression, not
        // several `<=` sites resolved by position, so the resolution is a boolean:
        //   next = cpu_inta & (old | answer)   [answer implies cpu_inta, so the clear can
        //                                      only fire while the strobe is low]
        inta_responded <= cpu_inta && (inta_responded | inta_arm);
    end
end

`ifdef VERILATOR
  // ---------------------------------------------------------------------------
  // R8: THE CONTRACT THE UNCONDITIONAL S_INTA1 EXIT RESTS ON (docs/single-cycle-event-
  // discipline.md R5/R6/R8). `inta_responded` is the taken flag - one answer per asserted
  // strobe - and S_INTA1 does not wait for the level because the flag, not the wait,
  // enforces the release. Both halves of that sentence are pinned here; they cost nothing
  // in synthesis and run in every bench that builds this module.
  // ---------------------------------------------------------------------------
  reg inta_arm_q;   // the arm answered the CPU last cycle
  reg ready_q;      // cpu_inta_ready was asserted last cycle
  always @(posedge clk) begin
    if (!reset_n) begin
      inta_arm_q <= 1'b0;
      ready_q    <= 1'b0;
    end else begin
      // (1) THE FLAG HOLDS FOR THE WHOLE STROBE. The cycle after an answer with the
      //     strobe still asserted must still show the flag set; a clear that did not wait
      //     for the release would let a held strobe be answered once per cycle.
      if (inta_arm_q && cpu_inta && !inta_responded)
        $error("pc9821_inta_bridge: the taken flag cleared while inta is still asserted - a held strobe would be answered twice (R5/R6)");
      // (2) ONE READY PULSE PER BUS CYCLE. The first INTA's ready and the vector handoff's
      //     ready are this module's two ready pulses; a second one in the next cycle is a
      //     double acknowledge of the same strobe (the shape a held inta drives).
      if (ready_q && cpu_inta_ready)
        $error("pc9821_inta_bridge: cpu_inta_ready in two consecutive cycles - one INTA strobe answered twice (R8)");
      inta_arm_q <= inta_arm;
      ready_q    <= cpu_inta_ready;
    end
  end
`endif

endmodule

`default_nettype wire
