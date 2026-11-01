// 8259 PIC - PC-9821 MiSTer core: the Intel 8259A pair.
//
// Master: command 0x00 / data 0x02. Slave: command 0x08 / data 0x0A.
// IRQ 0 = PIT timer, IRQ 1 = keyboard, IRQ 2 = the GDC VSYNC; the cascaded slave
// is on IRQ 7. On the slave (IRQ8..IRQ15) the bus mouse is IR5 = IRQ13
// (NP2kai mouseint, io/mouseif.c:131-140); its device raises a one-clk pulse
// per periodic event and this PIC latches it like every other line (ir_set is
// the rising-edge term below).
//
// WD_MASK / the FALLING-EDGE WITHDRAW. The machine does not hold every request
// in the edge latch forever: the 2026-10-02 IRQWD probe (docs/probes/IRQWD.TXT)
// measured, on the real Xe10, that while IRQ0 is masked the master IRR bit 0
// FOLLOWS THE PIT CHANNEL-0 OUT PIN (2826 falls / 2826 rises with ch0 in mode
// 3), and that the keyboard (IRQ1) and IDE (IRQ9) requests clear when their
// acking register read lowers the device line. IRQ2 (VSYNC, the in-service
// measurement in docs/probes/VSYNC.TXT) and IRQ12 (OPNA register 0x27) HOLD.
// So the machine is a per-line mix, and WD_MASK names the lines that clear
// their latched request on the device line's FALLING edge while the line is
// MASKED. Gating on the mask is deliberate: an unmasked falling edge landing in
// the cycles before INTA must not lose a real interrupt, and for a masked
// request the falling edge is exactly what the game's IRR poll waits on
// (STEELGUN). The unmasked path is unchanged - INTA already cleared the latch.
//
// WD_UNMASKED / THE KEYBOARD'S ACKING READ. One line needs the withdraw on the
// falling edge even while UNMASKED: IRQ1. Its line falls only when the guest has
// just read the data register (pc9821_kbd's `irq = status[1] && !st_read ...`),
// i.e. when the pending request has been SERVICED BY POLLING and is no longer
// owed an interrupt. Holding the edge latch there makes the PIC dispatch the
// already-consumed byte, and the guest's INT 09h reads the stale data register
// and queues a duplicate key - measured as an `85:xx` (RXRDY clear) INT 09h in
// the KBIRQ probe on the Xe10 image after a make/break bounce. The masked case
// is the IRQWD capture (docs/probes/IRQWD.TXT: `IRQ1 ... postack_irr=01`).
// The master also names IRQ0 here (pc9821_interrupts): OUT0 falls only when the
// guest reprograms channel 0 (mode 0 control word or mode-0 count) or a square
// wave's half period ends, and NP2kai clears IRR0 on every channel-0 write
// (io/pit.c pit_o71 / pit_o77) while the Xe10's IRR follows OUT0 (IRQWD). A
// request that falls before its acknowledge is lost on the real 8259A too.
//
`default_nettype none

module pc9821_pic #(
    parameter BASE_VEC = 8'h08,
    // Input bit the cascaded slave drives, or -1 for a controller that is
    // itself a slave. Only a cascaded master has the SFNM exemption below.
    parameter integer CASCADE_IRQ = -1,
    // Lines whose latched request is withdrawn by the device line's falling edge
    // while masked (see the header). 0 = the pure edge latch.
    parameter [7:0] WD_MASK = 8'h00,
    // Lines whose latched request is withdrawn by the device line's falling edge
    // whether masked or not: the acking-register-read lines (IRQ1), whose falling
    // edge MEANS the request was consumed. See the header.
    parameter [7:0] WD_UNMASKED = 8'h00
) (
    input wire clk,
    input wire rst_n,

    input  wire       cs,
    input  wire       wr,
    // UNUSED HERE, AND THAT IS A FINDING, NOT A CHOICE: this PIC drives dout from a0 alone
    // (see the assign below), while pc9821_pit qualifies the same kind of read with
    // `cs && rd`. One PC-98 peripheral honours the read strobe and the other does not.
    // Nothing has failed because of it - the bus samples dout on a read - so this is waived
    // rather than changed, and reported so the two can be made to agree deliberately.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire       rd,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire       a0,
    input  wire [7:0] din,
    output wire [7:0] dout,

    input  wire [7:0] ir_in,
    output reg        int_out,
    output reg  [7:0] int_vec,
    output wire [2:0] int_irq,
    // The IRQ the LAST acknowledge put in service, latched on the acknowledge edge.
    // int_irq tracks the live highest-priority pending request (the cascade
    // acknowledge needs that at the acknowledge edge); this one is frozen once the
    // ack is taken, so the vector a cascade MUX selects is the vector the acked IRQ
    // names rather than a later request's.
    output reg  [2:0] int_acked_irq,
    // Whether that acknowledge found a request at all. 0 = spurious (inta with
    // nothing to serve): int_acked_irq then holds the PREVIOUS ack's value and must
    // not be trusted to pick the vector source.
    output reg        int_acked_valid,
    input  wire       inta,

    // Live register state for telemetry: whether a request is masked,
    // latched but suppressed, or already in service.
    output wire [7:0] dbg_imr,
    output wire [7:0] dbg_irr,
    output wire [7:0] dbg_isr
);

  reg [7:0] isr, imr;
  reg [7:0] icw2_vec;
  reg icw_active, icw4_needed, icw3_needed;
  reg icw4_sfnm;
  reg [1:0] icw_step;
  reg aeoi, read_irr;
  // Auto-EOI rotate: OCW2 R=1, SL=0, EOI=0 arms a mode in which every acknowledge advances the
  // priority pointer one step (ao486 rtl/soc/pic/pic.v: `ocw2 && io_writedata[6:0] == 0` sets it,
  // `acknowledge_not_spurious && auto_eoi && rotate_on_aeoi` rotates). NP2kai has no AEOI at all,
  // so the datasheet/QEMU/ao486 answer governs AEOI here; see W5.
  reg rotate_on_aeoi;
  reg smm;                 // OCW3 special mask mode (ESMM/SMM)
  reg [2:0] pry;           // OCW2 priority pointer
  reg     [7:0] ir_latch;
  reg     [7:0] ir_prev;  // registered IR inputs (rising-edge detector)
  reg     [2:0] int_hold; // cycles to keep INT deasserted after an ack

  // the highest-priority unmasked, unserviced request (declared before ir_clr,
  // which reads highest_valid)
  //
  // In-service priority block: bit k is set when a request of priority k or higher is
  // in service, so a lower-priority request cannot be forwarded while a higher one is
  // handled (QEMU: `cur_priority = get_priority(isr); if (priority < cur_priority)
  // return -1`). Without it a non-specific EOI can clear the wrong ISR bit and
  // re-enter the timer ISR. "Priority" here is the rotated one below, not IRQ number.
  // Special fully nested mode. The machine's own ITF programs the master with
  // ICW4 = 0x1D (SFNM, buffered, master) and the slave with 0x09
  // (BANK4@0x4BB1-0x4BC3), and the option-ROM disk ISR relies on it: it omits the
  // master EOI while another slave request is in service. Under SFNM the cascade input
  // is exempt from the priority block, so a second slave request is forwarded while
  // isr[7] is set - QEMU's i8259 does the same (`mask &= ~(1 << 7)`).
  wire sfnm_cascade = icw4_sfnm && (CASCADE_IRQ >= 0);
  // Special mask mode: an in-service level does not block a lower-priority request.
  // QEMU removes the MASKED in-service lines from the block
  // (`mask = isr; if (special_mask) mask &= ~imr;`, hw/intc/i8259.c:87-88) and NP2kai
  // drops the whole ISR (`if (!(ocw3 & SMM)) mir |= isr;`, io/pic.c:163); this core takes
  // QEMU's rule, which is the one that keeps an unmasked in-service level blocking.
  wire    [7:0] isr_eff = smm ? (isr & ~imr) : isr;
  // Under SFNM the cascade input never blocks: an in-service IRQ7 does not suppress a
  // forwarded request, so it is dropped from the block's SOURCE. That is exactly what
  // `|isr_eff[6:0]` gives for bit 7 at pry=0, and it stays true at any pry.
  wire    [7:0] isr_blk_src = sfnm_cascade ? (isr_eff & 8'h7F) : isr_eff;
  // PRIORITY IS COUNTED FROM THE OCW2 POINTER, NOT FROM IRQ0. Rotate the
  // in-service levels so rotated index 0 IS the level `pry` makes highest - the order
  // the `highest` scan above already walks - then a cumulative OR over that order is a
  // cumulative OR over priority, and rotating the result back names the levels it
  // blocks. QEMU reaches the same answer by comparing the request's priority against
  // the one derived from the ISR relative to s->priority_add (hw/intc/i8259.c:80-105).
  // On natural IRQ order alone a pry != 0 BLOCKS the level the pointer promotes and
  // lets the level it demotes preempt.
  // The rotate / cumulative-OR / rotate-back of the in-service levels, written without the two
  // barrel rotators: level p is blocked when an in-service level lies in priority order from
  // `pry` up to and including p. For p >= pry that is a prefix OR of the levels at or above
  // `pry`; for p < pry the order wraps, so it is any in-service level at or above `pry`, or one
  // at or below p. Equal to the rotated form for every (isr_blk_src, pry) (checked exhaustively
  // over all 256 x 8 inputs when it was written).
  wire    [7:0] isr_ge    = isr_blk_src & (8'hFF << pry);
  wire          isr_any_ge = |isr_ge;
  reg     [7:0] isr_block;
  always @(*) begin : blk
    integer p;
    reg pre_ge, pre_all;
    pre_ge = 1'b0; pre_all = 1'b0;
    for (p = 0; p < 8; p = p + 1) begin
      pre_ge  = pre_ge  | isr_ge[p];
      pre_all = pre_all | isr_blk_src[p];
      isr_block[p] = (p[2:0] >= pry) ? pre_ge : (isr_any_ge | pre_all);
    end
  end
  wire    [7:0] pending = ir_latch & ~imr & ~isr_block;
  reg     [2:0] highest;
  reg           highest_valid;

  // request latch next-state pieces (single NBA per cycle, see the update site)
  wire    [7:0] ir_set = ir_in & ~ir_prev;
  wire    [7:0] ir_clr = (inta && highest_valid) ? (8'h01 << highest) : 8'h00;
  // Per-line falling-edge withdraw, gated on the mask (the IRQWD machine result;
  // see the WD_MASK header note). ir_fall and ir_set can never name the same bit,
  // so there is no set-vs-withdraw collision to resolve.
  wire    [7:0] ir_fall   = ~ir_in & ir_prev;
  wire    [7:0] ir_wd_eff = ir_fall & ((WD_MASK & imr) | WD_UNMASKED);
  wire    [7:0] ir_clr_all = ir_clr | ir_wd_eff;
  assign int_irq = highest;

  // OCW2's level and the request scan both start at the priority pointer and wrap
  // (NP2kai io/pic.c:156-166 and :295-305: `num = pry; while(!(mir & (1<<num)))
  // num = (num+1) & 7;`). k = 7..0 with idx = (pry+k)&7 makes pry win last, i.e.
  // highest priority.
  // The first set level counting up from `pry` and wrapping: the lowest set bit at or above
  // `pry`, else the lowest set bit overall (two fixed priority encoders and a select, where the
  // 8-step scan indexed by pry + k built eight 8:1 muxes).
  function automatic [3:0] low_enc(input [7:0] x);   // {valid, index of the lowest set bit}
    begin
      low_enc = x[0] ? 4'b1000 : x[1] ? 4'b1001 : x[2] ? 4'b1010 : x[3] ? 4'b1011 :
                x[4] ? 4'b1100 : x[5] ? 4'b1101 : x[6] ? 4'b1110 : x[7] ? 4'b1111 : 4'b0000;
    end
  endfunction
  function automatic [3:0] first_from(input [7:0] x, input [2:0] from);
    reg [3:0] e_ge;
    begin
      e_ge = low_enc(x & (8'hFF << from));
      first_from = e_ge[3] ? e_ge : low_enc(x);
    end
  endfunction
  wire [3:0] pend_first = first_from(pending, pry);
  always @(*) begin
    highest       = pend_first[2:0];
    highest_valid = pend_first[3];
  end

  // OCW2's level: the SL field when set, else the first in-service level scanning from
  // the priority pointer (NP2kai io/pic.c:295-300). `ocw2_has` is false only for the
  // SL=0 / no-ISR case, where NP2kai changes nothing at all.
  wire [3:0] isr_first = first_from(isr, pry);
  reg [2:0] ocw2_lvl;
  reg       ocw2_has;
  always @(*) begin
    ocw2_has = 1'b1;
    ocw2_lvl = din[2:0];
    if (!din[6]) begin
      ocw2_has = isr_first[3];
      ocw2_lvl = isr_first[3] ? isr_first[2:0] : pry;
    end
  end

  // single always block for all sequential logic
  always @(posedge clk) begin
    if (!rst_n) begin
      isr           <= 8'h00;
      imr           <= 8'hFF;
      icw2_vec      <= BASE_VEC;
      icw_active    <= 1'b0;
      icw_step      <= 2'd0;
      icw4_needed   <= 1'b0;
      icw3_needed   <= 1'b0;
      aeoi          <= 1'b0;
      rotate_on_aeoi <= 1'b0;
      icw4_sfnm     <= 1'b0;
      read_irr      <= 1'b1;
      smm           <= 1'b0;
      pry           <= 3'd0;
      ir_latch      <= 8'h00;
      ir_prev       <= 8'h00;
      int_out       <= 1'b0;
      int_hold      <= 3'd0;
      int_vec       <= 8'h00;
      int_acked_irq <= 3'd0;
      int_acked_valid <= 1'b0;
    end else begin
      // 8259 edge-triggered request latch: set on a rising edge of IR, held until INTA
      // clears the serviced bit. A still-held level does NOT re-set after INTA (no new
      // edge), and a falling edge does not withdraw an unacknowledged request (short PIT
      // pulses survive).
      //
      // SINGLE assignment: the edge latch and the INTA clear are folded into one
      // expression. A separate `ir_latch[highest] <= 1'b0` NBA races with this
      // whole-vector update - the clear is lost and every interrupt re-asserts forever.
      // SET WINS on a same-bit collision (race-idiom R3): a rising edge landing on the
      // acknowledge edge of the same level is a NEW request - the ack consumed the old
      // one - and `(latch | set) & ~clr` ate it, losing one interrupt per acknowledge
      // window with no way for an edge source to re-request. tb_pc9821_pic's
      // same-cycle collision case pins this.
      ir_prev  <= ir_in;
      // clear = INTA (ir_clr) OR the machine's masked falling-edge withdraw
      // (ir_wd_eff); SET WINS on a same-bit collision (race-idiom R3).
      ir_latch <= (ir_latch & ~ir_clr_all) | ir_set;

      // I/O write
      if (cs && wr) begin
        if (!a0) begin
          if (din[4]) begin
            // ICW1: A0=0, D4=1. D3 is LTIM, not part of the opcode.
            // D1=SNGL (1 = no ICW3); D0=IC4.
            icw_active  <= 1'b1;
            icw_step    <= 2'd0;
            icw4_needed <= din[0];
            icw3_needed <= ~din[1];
            // ICW1 clears the pending-request state (imr/irr below) but
            // deliberately NOT the ISR: NP2kai's pic_o00 clears imr/irr/ocw3/pry
            // and leaves the isr clear disabled inside `#if 0`
            // (io/pic.c:326-337) - a guest that re-inits while an interrupt is
            // in service keeps the in-service bit. QEMU
            // clears it (pic_reset_common) but the 8259A datasheet's ICW1 reset
            // list does not name the ISR, and NP2kai is the primary reference.
            // Showing a stale mask to a guest that reads it and writes it back is
            // how a boot ends up with a mask nobody intended - that is the imr
            // clear, which stays.
            imr         <= 8'h00;
            ir_latch    <= 8'h00;
            read_irr    <= 1'b1;
            smm         <= 1'b0;
            pry         <= 3'd0;
            rotate_on_aeoi <= 1'b0;
          end else if (din[3]) begin
            // OCW3: A0=0, D4=0, D3=1
            // RIS selects the ISR only when RR is set as well (QEMU hw/intc/i8259.c and
            // MAME gate it; NP2kai does NOT - io/pic.c:315-318 `if (!(dat & PIC_OCW3_RR))`
            // keeps an RIS written without RR - a divergence tb_pc9821_pic_ref waives).
            if (din[1]) read_irr <= ~din[0];
            // ESMM (D6) gates the SMM write; with ESMM=0 SMM keeps its old value
            // (NP2kai io/pic.c:319-322, QEMU hw/intc/i8259.c:252-254).
            if (din[6]) smm <= din[5];
          end else if (!din[4]) begin
            // OCW2 (EOI / rotate): A0=0, D4=0, D3=0. R (D7) rotates the priority
            // pointer to level+1, EOI (D5) clears the level, SL (D6) takes the level
            // from L (D2:0) instead of the in-service scan (NP2kai io/pic.c:291-306).
            if (ocw2_has) begin
              if (din[7]) pry <= (ocw2_lvl + 3'd1) & 3'd7;
              if (din[5]) isr[ocw2_lvl] <= 1'b0;
            end
            // Rotate-on-auto-EOI arming is independent of the EOI branch above (ao486):
            // an OCW2 with R=1 and SL=EOI=0 sets the mode from D7 (0x80 arms, 0x00 disarms).
            if (din[6:0] == 7'd0) rotate_on_aeoi <= din[7];
          end
        end else begin
          // port 1
          if (icw_active) begin
            case (icw_step)
              2'd0: begin
                icw2_vec <= din;
                // End the sequence here if nothing else is outstanding, as QEMU does
                // when ICW2 is written; advancing unconditionally eats the guest's next
                // write, its IMR.
                if (!icw3_needed && !icw4_needed) icw_active <= 1'b0;
                else if (!icw3_needed) icw_step <= 2'd2;   // ICW4 next
                else icw_step <= 2'd1;                     // ICW3 next
              end
              2'd1: begin
                // This write was ICW3; only ICW4 can still be outstanding.
                if (icw4_needed) icw_step <= 2'd2;
                else icw_active <= 1'b0;
              end
              2'd2: begin
                // ICW4 is expected only when ICW1 asked for it (D0). If it did not, this
                // slot is never written and the sequence must end here regardless.
                // Parking with icw_active still set consumes every later data-port write
                // as an ICW4, so the IMR becomes permanently unwritable.
                if (icw4_needed) begin
                  aeoi      <= din[1];
                  icw4_sfnm <= din[4];
                end
                icw_active <= 1'b0;
              end
              default: ;
            endcase
          end else begin
            imr <= din;
          end
        end
      end

      // interrupt acknowledge: IRR -> ISR
      if (inta && highest_valid) begin
        // ONE number, one edge. The ISR set below, the IRR clear (ir_clr, driven
        // from this same live `highest`), the vector and int_acked_irq all come
        // from the `highest` of THIS cycle. Driving int_vec from a live `highest`
        // sampled a cycle later let the vector name one IRQ while the ISR marked
        // another in service (VEC=14 slave with master ISR=IRQ0): the
        // vector is now latched here, on the acknowledge edge, and the bridge
        // reads it back, so the ack cannot split.
        int_acked_irq <= highest;
        int_vec       <= (icw2_vec & 8'hF8) | {5'd0, highest};
        if (!aeoi) begin
          case (highest)
            3'd0: isr[0] <= 1'b1;
            3'd1: isr[1] <= 1'b1;
            3'd2: isr[2] <= 1'b1;
            3'd3: isr[3] <= 1'b1;
            3'd4: isr[4] <= 1'b1;
            3'd5: isr[5] <= 1'b1;
            3'd6: isr[6] <= 1'b1;
            3'd7: isr[7] <= 1'b1;
          endcase
        end
        // ir_latch is cleared only via ir_clr in the single vector NBA
        // above; a second per-bit NBA raced with it.
        // AEOI rotate-on-acknowledge (ao486 pic.v): the not-spurious ack advances the
        // priority pointer so the just-serviced level becomes lowest priority. It must advance
        // from the level ACTUALLY acknowledged, not from the old base: QEMU's pic_intack sets
        // `priority_add = (irq + 1) & 7`, so a lone IRQ3 acked at pry=0 leaves IRQ4 highest -
        // `pry + 1` would wrongly make IRQ1 highest.
        if (aeoi && rotate_on_aeoi) pry <= (highest + 3'd1) & 3'd7;
      end

      // INT output (level: held until INTA - the ao486 samples it as a level at
      // writeback and pulses interrupt_done when it takes the vector).
      //
      // int_vec TRACKS the current highest-priority pending IRQ while INT is asserted
      // (the ao486 is slow to answer - hundreds of clk_sys, an SDRAM-backed vector
      // fetch - and another request can be latched in that time), but the acknowledge
      // LATCHES it to the IRQ it is about to put in service (the `inta` arm in the ack
      // block above). Tracking alone is what let the vector and the ISR disagree.
      if (inta) begin
        // ao486 interrupt_done is a one-cycle pulse. Acknowledge must win over
        // highest_valid from the pre-edge IRR value; otherwise INT stays high for one
        // extra CPU interrupt and produces a spurious INTA with no pending request.
        int_out   <= 1'b0;
        int_hold  <= 3'd4;
        // The ack event records what it found, so the vector mux upstream cannot key
        // on a stale previous ack.
        int_acked_valid <= highest_valid;
        // A spurious acknowledge - inta with nothing to serve (the request was
        // withdrawn between intr and the INTA pair) - publishes THIS chip's own
        // spurious vector icw2_vec | 7 (the 8259 convention: 0x0F on the master,
        // 0x17 on the slave), instead of leaving int_vec at whatever it last tracked.
        if (!highest_valid) int_vec <= icw2_vec | 8'h07;
        // Otherwise int_vec is not touched here: the ack block set it to the acked
        // IRQ's vector.
      end else if (int_hold != 3'd0) begin
        // Hold INT low for a few cycles after an acknowledge: the z486 microcode runs
        // CINTLA between the two IACK cycles and clears intr_latch_inhibit only on a
        // sample of intr == 0, so a one-cycle window is a race.
        int_hold <= int_hold - 3'd1;
        int_out  <= 1'b0;
      end else if (!icw_active && highest_valid) begin
        // The 8259A takes only bits 7:3 of ICW2 (NP2kai masks 0xf8, QEMU sets
        // irq_base = val & 0xf8); the low three bits come from the IRQ alone.
        int_vec <= (icw2_vec & 8'hF8) | {5'd0, highest};
        int_out <= 1'b1;
      end else begin
        // Nothing to forward: drop INT. Otherwise masking an already-asserted request
        // leaves INT high, and the CPU takes a level with no pending request behind it -
        // no ISR bit set and int_vec still holding its previous, stale value.
        int_out <= 1'b0;
        // Nothing pending: publish the spurious-interrupt vector the machine and QEMU
        // both answer, icw2_vec | 7. Returning 0x00 sends the CPU to IVT[0], the
        // divide-error entry, with a stack shaped for a device ISR.
        int_vec <= icw2_vec | 8'h07;
      end
    end
  end

  // read data
  assign dout = a0 ? imr : (read_irr ? ir_latch : isr);

  assign dbg_imr = imr;
  assign dbg_irr = ir_latch;
  assign dbg_isr = isr;

endmodule

`default_nettype wire
