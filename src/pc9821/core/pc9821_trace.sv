`default_nettype none

// The CPU instruction trace: one ring-buffer record per EIP transition, dumped over the UART.
// WHY. The watchdog message carries CS/EIP once every 2 s, so a capture says WHERE the guest is
// and never HOW IT GOT THERE. The card stops at ITF stage 0x1B, a rep stosd filling 32 KiB at
// ES=0xA800, with EIP constant - and a constant EIP is what a WEDGE and a SLOW rep look like
// identically. An EIP transition IS an instruction boundary, so recording transitions is a
// per-instruction trace rather than a sample, which is the whole point of this module.

// DWELL SEPARATES THE TWO CASES. A rep holds EIP constant across all its iterations, so a bare
// PC trace records it ONCE and cannot say whether the rep is grinding through 8192 stores or
// stopped on its first. dwell counts the cycles spent at that PC: a huge final dwell is a
// wedge, many records with small dwells are progress.

// THE RING IS M10K, NOT SDRAM, DELIBERATELY. What is failing is the path to SDRAM, so a trace
// that depended on it would stop recording exactly when it is wanted. Memory is also the
// resource this design has spare (29% used against 96% of the LABs).

// The output is ASCII hex, one record per line, because the debug UART is shared with the
// watchdog message and an operator reads both through `cat /dev/ttyS1`. The two interleave and
// the decoder separates them by shape: a trace line is `CCCC:EEEEEEEE,DDDD`.
module pc9821_trace #(
    parameter integer AW           = 13,           // 8192 records, one per EIP transition
    parameter integer STALL_CYCLES = 10_000_000,   // 200 ms at 50 MHz
    parameter integer ARM_RECORDS  = 64            // transitions recorded before the detector arms
) (
    input  wire        clk,
    input  wire        reset,
    input  wire [15:0] cs,
    input  wire [31:0] eip,
    // THE STALL CONTEXT, latched at the instant the detector fires and printed once, ahead of the
    // records. The ring says WHERE the CPU was; this says WHAT IT WAS WAITING FOR, which is the
    // question a wedge cannot otherwise answer - predicted this stall and could not show it.
    // The address is the decisive field: an I/O port is below 0x10000 and GVRAM is at 0xA8000, so
    // the value alone separates the two paths that could be hanging.
    input  wire [31:0] ctx_addr,
    input  wire        ctx_write,
    input  wire        ctx_valid,
    input  wire        ctx_ready,
    input  wire        ctx_resp_valid,
    // The SECOND requester into the same SDRAM controller. It is the pack's font port, and it is
    // the one way mem0 can go unanswered while nothing in the GVRAM looks wrong: a font transfer
    // stuck in flight holds the controller. pc9821_system exports it as ext_mem1_valid, which IS
    // fmem_valid (pc9821_system.sv:1104, `.fmem_valid(ext_mem1_valid)`).
    input  wire        ctx_fmem_valid,
    // One-cycle freeze request (pc9821_system trace_trig): once armed, commit the current PC
    // with its dwell so far and dump exactly as a stall does, so the ring holds the transitions
    // that LED to the event. The OOM screen never stalls (a timer ISR keeps EIP moving), so the
    // stall alone cannot capture it.
    input  wire        trig,
    input  wire        out_ready,   // the UART FIFO can take a byte this cycle
    output wire [7:0]  out_byte,
    output wire        out_we
);

  localparam integer        RECORDS = 1 << AW;
  // THE COUNTERS ARE SIZED TO THEIR OWN BOUNDS, which are the parameters above and not 32 bits.
  // `records` saturates at RECORDS and `rd_left` counts down from RECORDS to 0, so both range
  // 0..RECORDS and $clog2(RECORDS+1) bits carry them (14 at the built AW=13, 4 at the bench's
  // AW=3); `stall_cnt` saturates at STALL_CYCLES, so it needs $clog2(STALL_CYCLES+1) (24 at the
  // built 50 MHz/5 = 10,000,000, 5 at the bench's 24). REC_BITS needs no floor (RECORDS is 1<<AW,
  // so at least 1); STALL_BITS carries one because STALL_CYCLES is a parameter that may be zero.
  localparam integer        REC_BITS = $clog2(RECORDS + 1);
  localparam integer        STALL_BITS = ($clog2(STALL_CYCLES + 1) < 1) ? 1 : $clog2(STALL_CYCLES + 1);

  // Recording. cur_* is the PC the CPU is AT; a record is committed when it leaves it, carrying
  // the cycles it stayed. dwell saturates rather than wrapping, so a wedge reads as 0xFFFF and
  // not as a small number that would look like a fast instruction.
  //
  // THE STALLED PC IS COMMITTED TOO, and it is the one record that must not be missing: a record
  // is normally written when the CPU LEAVES a PC, so the PC it is stuck on would never be written
  // at all. On the stall the current PC is committed with a saturated dwell first, which is both
  // the answer (this is where it stopped) and unmistakable (dwell 0xFFFF means it never left).
  reg [15:0]   cur_cs;
  reg [31:0]   cur_eip;
  reg [15:0]   dwell;
  reg          started;

  // The context snapshot. LATCHED AT THE STALL and not read live, because the dump takes about
  // sixteen seconds and anything that unstuck meanwhile would rewrite the answer while the
  // operator was still reading it. A snapshot of the instant of the stall is the useful thing.
  reg [31:0]   ctx_addr_q;
  reg          ctx_write_q, ctx_valid_q, ctx_ready_q, ctx_resp_q, ctx_fmem_q;
  reg [AW-1:0] wr_ptr;
  reg [REC_BITS-1:0]   records;
  reg [STALL_BITS-1:0] stall_cnt;
  reg          dumped;
  reg          dumping;

  wire        moved     = started && ((cs != cur_cs) || (eip != cur_eip));
  wire        dwell_sat = (dwell == 16'hFFFF);
  wire [63:0] rec_data  = {cur_cs, cur_eip, dwell_sat ? 16'hFFFF : dwell};

  // The detector arms only after ARM_RECORDS transitions. Without that, the constant PC of reset
  // and the first fetch would satisfy "unchanged for 200 ms" and every dump would hold startup.
  // WHY THE TRIGGER ARM RE-ARMS AND THE STALL ARM DOES NOT. The stall arm is one dump per run by
  // design and the bench pins it. The explicit trigger is driven by the PC-98 core
  // (pc9821_system's `trace_trig`, a ONE-CYCLE pulse), and what it is used for - a drawing burst
  // that ends with the guest waiting for input - happens many times in a session, so a
  // once-per-run dump would be spent on the first one and never see the one that reproduces the
  // fault. `trig_hold` is what keeps a pulse a one-shot: it is set by the pulse that fires and
  // cleared once the pulse is gone AND the dump has finished, so a trig held high cannot re-fire
  // and a later pulse can.
  reg trig_hold;
  // The arm comparison is HOISTED into one wire and shared: written twice it emitted
  // a second WIDTHEXPAND lint warning for the same `records >= ARM_RECORDS` widening,
  // and the tree's lint gate is a fixed count of pre-existing warnings, so a new
  // instance of an old warning is a new warning.
  wire enough      = (records >= ARM_RECORDS);
  wire armed_stall = !dumped && enough;
  wire armed_trig  = !trig_hold && enough;
  wire stall = armed_stall && (stall_cnt >= STALL_CYCLES);

  wire [AW-1:0] wr_next  = wr_ptr + {{(AW - 1) {1'b0}}, 1'b1};
  wire [REC_BITS-1:0] rec_after = (records == RECORDS) ? records : (records + 1'b1);
  wire [63:0]   stall_rec = {cur_cs, cur_eip, 16'hFFFF};

  // !dumping MUST GATE BOTH TERMS. `stall` stays high for the whole dump - stall_cnt is frozen
  // above the threshold and `dumped` is not set until the end - so with only `moved` gated the
  // ring would be rewritten every cycle at the post-stall wr_ptr, which is the OLDEST slot: the
  // dump would destroy the oldest record before reading it, and the first line would print the
  // stall record twice (a bench sees that as an order failure, since only one slot is clobbered).
  wire          fire    = stall || (armed_trig && trig);
  wire          ring_wr = (moved || fire) && !dumping;
  wire [63:0]   ring_d  = stall ? stall_rec : rec_data;

  localparam [2:0] S_IDLE = 3'd0, S_HDR = 3'd1, S_REC = 3'd2, S_FOOT = 3'd3, S_DONE = 3'd4,
                   S_CTX = 3'd5;

  reg [2:0]    state;
  reg [4:0]    line_idx;      // 0..19 within one record's line
  reg [4:0]    hdr_idx;
  // SIX BITS IN BOTH PLACES: ctx_idx and ctx_char's port must both be [5:0], or index 32 arrives
  // as 0 and the last four characters of the line repeat the start. A wide counter feeding a
  // narrow port truncates silently.
  reg [5:0]    ctx_idx;       // 0..35 within the context line
  reg [AW-1:0] rd_ptr;
  reg [REC_BITS-1:0] rd_left;
  reg [63:0]   rd_data;

  // THE BRAM READ IS REGISTERED, so the address must be presented one cycle before the byte is
  // wanted: during the last header byte for the first record, and during the last byte of each
  // line for the next. rd_ptr must already name the record q_b will carry, or the line printed
  // is the previous record's.
  wire          prefetch_hdr = (state == S_HDR) && (hdr_idx == 5'd8);
  // The context line sits between the header and the first record, so ONE of the two prefetches
  // fires and never both: whichever line ends last must already have named the first record.
  wire          prefetch_ctx = (state == S_CTX) && (ctx_idx == 6'd35);
  wire          prefetch_rec = (state == S_REC) && (line_idx == 5'd19);
  wire [AW-1:0] wr_next_ptr  = rd_ptr + {{(AW - 1) {1'b0}}, 1'b1};
  wire [AW-1:0] dump_rd_addr = prefetch_rec ? wr_next_ptr : rd_ptr;
  wire          dump_rd_en   = prefetch_hdr || prefetch_ctx || prefetch_rec;

  /* verilator lint_off PINCONNECTEMPTY */   // port A is write-only here; the dump reads on port B
  pc9821_dpram #(.AW(AW), .DW(64)) u_ring (
      .clock_a(clk), .address_a(wr_ptr), .data_a(ring_d), .wren_a(ring_wr), .q_a(),
      .clock_b(clk), .en_b(dump_rd_en), .address_b(dump_rd_addr), .data_b(64'd0), .wren_b(1'b0),
      .q_b(rd_data)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // "\r\nTRACE\r\n" and "\r\nTRACE END\r\n", spelled as bytes so nothing depends on how a
  // toolchain interprets an escape inside a string literal.
  function [7:0] hdr_char(input [4:0] i);
    case (i)
      5'd0: hdr_char = 8'h0D; 5'd1: hdr_char = 8'h0A;
      5'd2: hdr_char = "T";   5'd3: hdr_char = "R";   5'd4: hdr_char = "A";
      5'd5: hdr_char = "C";   5'd6: hdr_char = "E";   5'd7: hdr_char = 8'h0D;
      default: hdr_char = 8'h0A;
    endcase
  endfunction

  function [7:0] ftr_char(input [4:0] i);
    case (i)
      5'd0: ftr_char = 8'h0D; 5'd1: ftr_char = 8'h0A;
      5'd2: ftr_char = "T";   5'd3: ftr_char = "R";   5'd4: ftr_char = "A";
      5'd5: ftr_char = "C";   5'd6: ftr_char = "E";   5'd7: ftr_char = " ";
      5'd8: ftr_char = "E";   5'd9: ftr_char = "N";   5'd10: ftr_char = "D";
      5'd11: ftr_char = 8'h0D;
      default: ftr_char = 8'h0A;
    endcase
  endfunction

  function [7:0] hexchar(input [3:0] v);
    hexchar = (v < 4'd10) ? (8'h30 + {4'd0, v}) : (8'h41 + {4'd0, v} - 8'd10);
  endfunction

  function [7:0] rec_char(input [4:0] i, input [63:0] r);
    reg [3:0] nib;
    begin
      case (i)
        5'd4:    rec_char = ":";
        5'd13:   rec_char = ",";
        5'd18:   rec_char = 8'h0D;
        5'd19:   rec_char = 8'h0A;
        default: begin
          // rec_data is {cs[63:48], eip[47:16], dwell[15:0]}, so each field's MSB is its top bit
          // and not a shared 63: EIP starting at 31 read into dwell and printed "01000004" for
          // an EIP of 0x00000100.
          if (i < 5'd4)       nib = r[63 - {i, 2'b00} -: 4];
          else if (i < 5'd13) nib = r[47 - {(i - 5'd5), 2'b00} -: 4];
          else                nib = r[15 - {(i - 5'd14), 2'b00} -: 4];
          rec_char = hexchar(nib);
        end
      endcase
    end
  endfunction

  // THE STALL CONTEXT LINE, 32 characters plus CR and LF, printed once between the header and the
  // first record. Every field is labelled in the output itself, because an operator reading a raw
  // capture through `cat /dev/ttyS1` has nothing else to tell them what a bare hex run means.
  //
  //   CTX A=AAAAAAAA W=v V=v R=v S=v F=v
  //       A  the ADDRESS the port was driving when the detector fired - what the CPU waited on
  //       W  that transaction's write bit (1 = store, 0 = load)
  //       V  the port's request valid - held high for the whole wait
  //       R  the port's ready       - the answer that never came
  //       S  the response valid
  //       F  the FONT port's request valid, the other requester into the same controller
  //
  // THE ADDRESS CARRIES THE SPLIT BY ITSELF: an I/O port is below 0x10000, GVRAM is at 0xA8000,
  // and the font's pack window is higher still, so a value says which path hung without a second
  // instrument. V=1 with R=0 is a request PRESENTED AND REFUSED; V=0 while the GVRAM believes it
  // is waiting means the request never reached the port and the fault is above it.
  function [7:0] ctx_char(input [5:0] i);
    reg [3:0] nib;
    begin
      case (i)
        6'd0:  ctx_char = "C";   6'd1:  ctx_char = "T";   6'd2:  ctx_char = "X";
        6'd3:  ctx_char = " ";   6'd4:  ctx_char = "A";   6'd5:  ctx_char = "=";
        6'd14: ctx_char = " ";   6'd15: ctx_char = "W";   6'd16: ctx_char = "=";
        6'd18: ctx_char = " ";   6'd19: ctx_char = "V";   6'd20: ctx_char = "=";
        6'd22: ctx_char = " ";   6'd23: ctx_char = "R";   6'd24: ctx_char = "=";
        6'd26: ctx_char = " ";   6'd27: ctx_char = "S";   6'd28: ctx_char = "=";
        6'd30: ctx_char = " ";   6'd31: ctx_char = "F";   6'd32: ctx_char = "=";
        6'd34: ctx_char = 8'h0D; 6'd35: ctx_char = 8'h0A;
        default: begin
          nib = (i < 6'd6)  ? 4'd0 :                 // 6..13 is the address, MSB first
                (i < 6'd14) ? ctx_addr_q[31 - {(i - 6'd6), 2'b00} -: 4] :
                (i == 6'd17) ? {3'd0, ctx_write_q} :
                (i == 6'd21) ? {3'd0, ctx_valid_q} :
                (i == 6'd25) ? {3'd0, ctx_ready_q} :
                (i == 6'd29) ? {3'd0, ctx_resp_q} :
                               {3'd0, ctx_fmem_q};
          ctx_char = hexchar(nib);
        end
      endcase
    end
  endfunction

  wire [7:0] cur_char =
      (state == S_HDR)  ? hdr_char(hdr_idx) :
      (state == S_CTX)  ? ctx_char(ctx_idx) :
      (state == S_REC)  ? rec_char(line_idx, rd_data) :
      (state == S_FOOT) ? ftr_char(hdr_idx) : 8'd0;

  // THE BYTE AND ITS VALID ARE COMBINATIONAL. The top level re-checks the FIFO in the cycle a byte
  // is presented, so presenting both in the cycle the FSM advances makes "offered" and "accepted"
  // one event; a registered form would drop any byte the watchdog put in the FIFO in between.
  assign out_byte = cur_char;
  assign out_we   = dumping && out_ready;

  always @(posedge clk) begin
    if (reset) begin
      cur_cs <= 16'd0; cur_eip <= 32'd0; dwell <= 16'd0; started <= 1'b0;
      wr_ptr <= {AW{1'b0}}; records <= {REC_BITS{1'b0}}; stall_cnt <= {STALL_BITS{1'b0}};
      dumped <= 1'b0; dumping <= 1'b0; state <= S_IDLE; trig_hold <= 1'b0;
      line_idx <= 5'd0; hdr_idx <= 5'd0; ctx_idx <= 5'd0; rd_ptr <= {AW{1'b0}};
      rd_left <= {REC_BITS{1'b0}};
      ctx_addr_q <= 32'd0; ctx_write_q <= 1'b0; ctx_valid_q <= 1'b0;
      ctx_ready_q <= 1'b0; ctx_resp_q <= 1'b0; ctx_fmem_q <= 1'b0;
    end else begin
      if (!dumping) begin
        // The trigger's one-shot latch releases only once the pulse is gone and the dump that it
        // caused has ended, so the NEXT pulse is a fresh event rather than the same one re-firing.
        if (!trig) trig_hold <= 1'b0;
        if (!started) begin
          started <= 1'b1; cur_cs <= cs; cur_eip <= eip; dwell <= 16'd0;
        end else if (moved) begin
          wr_ptr <= wr_next;
          records <= rec_after;
          cur_cs <= cs; cur_eip <= eip; dwell <= 16'd0;
        end else if (!dwell_sat) begin
          dwell <= dwell + 16'd1;
        end

        if (moved) stall_cnt <= {STALL_BITS{1'b0}};
        else if (stall_cnt != STALL_CYCLES) stall_cnt <= stall_cnt + 1'b1;

        if (fire) begin
          wr_ptr <= wr_next;
          records <= rec_after;
          dumping <= 1'b1;
          if (armed_trig && trig) trig_hold <= 1'b1;
          state <= S_HDR;
          hdr_idx <= 5'd0;
          ctx_idx <= 5'd0;
          line_idx <= 5'd0;
          // THE SNAPSHOT IS TAKEN HERE, in the one cycle the detector fires, because the dump takes
          // about sixteen seconds and a live read would report a later moment than the stall.
          ctx_addr_q  <= ctx_addr;
          ctx_write_q <= ctx_write;
          ctx_valid_q <= ctx_valid;
          ctx_ready_q <= ctx_ready;
          ctx_resp_q  <= ctx_resp_valid;
          ctx_fmem_q  <= ctx_fmem_valid;
          // The record just committed is part of what must be dumped, so the read window is the
          // POST-commit ring: from 0 while it has never wrapped, otherwise from the oldest slot.
          rd_left <= rec_after;
          rd_ptr <= (rec_after >= RECORDS) ? wr_next : {AW{1'b0}};
        end
      end else if (out_ready) begin
        case (state)
          S_HDR: begin
            if (hdr_idx == 5'd8) begin
              hdr_idx <= 5'd0;
              // The context line always prints, because a dump with no context is a list of where
              // the CPU had been and no statement of what it was waiting for.
              state   <= S_CTX;
              ctx_idx <= 5'd0;
            end else begin
              hdr_idx <= hdr_idx + 5'd1;
            end
          end
          S_CTX: begin
            if (ctx_idx == 6'd35) begin
              ctx_idx <= 5'd0;
              state <= (rd_left == {REC_BITS{1'b0}}) ? S_FOOT : S_REC;
            end else begin
              ctx_idx <= ctx_idx + 5'd1;
            end
          end
          S_REC: begin
            if (line_idx == 5'd19) begin
              line_idx <= 5'd0;
              rd_ptr <= wr_next_ptr;
              rd_left <= rd_left - 1'b1;
              if (rd_left == {{(REC_BITS-1){1'b0}}, 1'b1}) state <= S_FOOT;
            end else begin
              line_idx <= line_idx + 5'd1;
            end
          end
          S_FOOT: begin
            if (hdr_idx == 5'd12) begin
              state <= S_DONE;
              dumped <= 1'b1;
              dumping <= 1'b0;
            end else begin
              hdr_idx <= hdr_idx + 5'd1;
            end
          end
          default: state <= S_DONE;
        endcase
      end
    end
  end

endmodule

`default_nettype wire
