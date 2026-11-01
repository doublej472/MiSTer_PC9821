// WHICH debug record is being emitted, which byte of it is presented, and the PACING that keeps a
// 707-byte report from outrunning the 512-byte FIFO behind it.

// One report is THREE records in a row: the 351-byte stall record, the 256-byte PRF record, the
// 100-byte GFX record. The formatters are pure functions of a byte index and live in their own
// modules; this module owns the sequencing between them and the handshake to the UART FIFO. It is
// separate from pc9821_system.sv so the handshake has its own bench.

// THE PACING. The FIFO holds 512 bytes and drains at ~1 byte per 87 us, so a 707-byte report
// cannot be presented at one byte per clk_sys: the burst overran the FIFO, the overflow boundary
// landed inside the PRF record's last field, and the rest of the PRF plus the whole GFX record
// were dropped (the `AP=0` truncation). Every byte is therefore HELD until the FIFO takes it. The
// formatters SNAPSHOT their counters at the report's accept (their `snap` input, driven from the
// trigger's `start`), so a record's digits are one instant and the ratios in it stay honest
// however long the emission waits; the live counters keep counting through the emission (CY
// advances regardless, as its own contract states), so the next interval measures window plus
// emission.

// `dbg_uart_accept` IS NOT SIMPLY "ROOM": the reset banner and the instruction trace outrank the
// watchdog in the FIFO's enqueue chain, so a byte is accepted only when that chain would actually
// select this source. Advancing on room alone would step over a byte whenever the trace won.
`default_nettype none

module pc9821_dbg_record (
    input  wire       clk_sys,
    input  wire       reset,
    // The debug UART FIFO took the byte presented this cycle. A LEVEL: a byte stays presented
    // (dbg_we high, the same dbg_byte) for as many cycles as this is low.
    input  wire       dbg_uart_accept,
    // The watchdog trigger and the three formatters, all in clk_sys.
    input  wire       wdg_start,   // begin a report; one cycle, from pc9821_wdg_trigger
    input  wire [7:0] wdg_path,    // 'W'/'S'/'P', held by the trigger for the whole report
    input  wire [7:0] wdg_char,    // pc9821_watchdog_msg's byte for wdg_idx
    input  wire [7:0] prf_char,    // pc9821_perf_msg's byte for prf_idx
    input  wire [7:0] gfx_char,    // pc9821_gfx_msg's byte for gfx_idx
    output reg  [7:0] dbg_byte,    // the byte to emit this cycle
    output reg        dbg_we,      // ... and its valid, held while the byte is not accepted
    // Which byte of which record those are. The formatters are addressed by index, so the
    // counters are part of this module's state and are exported here.
    // NINE BITS: 0..350, the record being 351 characters (eight bits would not do).
    output reg [ 8:0] wdg_idx,
    output reg  [8:0] prf_idx,     // 0..255 (pc9821_perf_msg's PRF_MSG_LEN - 1)
    output reg  [6:0] gfx_idx,     // 0..99  (pc9821_gfx_msg's GFX_MSG_LEN - 1)
    // A report is in flight. This is the trigger's `hold`: it freezes the trigger's windows while
    // the record is being emitted, so the counters inside it are one interval's and the next
    // trigger cannot cut in between the three records that make one report.
    output wire       report_active
);

// THE TRIGGER BYTE IS THE SECOND-TO-LAST, index 349; THE LAST BYTE IS THE LF THAT ENDS THE LINE.
// The three triggers emit identical characters and this byte is what separates them - the
// selection is pc9821_wdg_trigger.sv, which has a bench, and here it is only substituted:
//   W = WEDGED - a request is OUTSTANDING and nothing has COMPLETED for 200 ms; the machine stopped.
//   S = the CPU stopped ASKING - no request for 200 ms. Halted or a long I/O wait; usually healthy.
//   P = the heartbeat, emitted whether or not anything is wrong. ON ITS OWN IT SAYS NOTHING ABOUT
//       PROGRESS: a wedge HOLDS z_valid high, so a stall arm that required `!z_valid` would let
//       P be read as progress while the machine is stalled.
// Emitting the trigger BEFORE the newline is what stops a tty's ICRNL (CR -> a second newline, the
// blank line removed) from gluing it to the next record. wdg_path is read live at index 349
// and is stable because the trigger's own `hold` covers the report. check_telemetry_contract.py
// holds these two indices to the formatter's ROM: the index is a coordinate written down in two
// files.
localparam [15:0] WDG_TRIG_IDX = 16'd349;   // pc9821_watchdog_msg.sv holds '?' at this index
localparam [15:0] WDG_MSG_LAST = 16'd350;   // and the LF that ends the record at this one

reg        wdg_active;   // a record is in flight; the trigger's counters freeze
reg        prf_active;   // the PRF record is in flight, straight after the stall record
reg        gfx_active;   // the GFX record is in flight, straight after the PRF record

assign report_active = wdg_active || prf_active || gfx_active;

// THE PRESENTED BYTE IS A FUNCTION OF THE STATE, NOT A REGISTERED COPY OF IT. With a copy one
// cycle behind the index, a report's LAST byte would be presented in the cycle after its record had
// gone inactive, so the strobe would drop at the next edge whether or not the FIFO had taken it - a
// byte lost per report at the one moment the pacing matters, and the GFX record's terminating LF at
// that. Presenting from the live index keeps the strobe on the byte until its own accept. The byte
// is also STABLE while held: the formatters read their report-accept snapshot (not live counters),
// so a held digit byte cannot mutate under the pacing.
always @(*) begin
    if (wdg_active) begin
        dbg_byte = (wdg_idx == WDG_TRIG_IDX) ? wdg_path : wdg_char;
        dbg_we   = 1'b1;
    end else if (prf_active) begin
        dbg_byte = prf_char;
        dbg_we   = 1'b1;
    end else if (gfx_active) begin
        dbg_byte = gfx_char;
        dbg_we   = 1'b1;
    end else begin
        dbg_byte = 8'd0;
        dbg_we   = 1'b0;
    end
end

always @(posedge clk_sys) begin
    if (reset) begin
        wdg_active <= 1'b0; wdg_idx <= 9'd0;
        prf_active <= 1'b0; prf_idx <= 9'd0;
        gfx_active <= 1'b0; gfx_idx <= 7'd0;
    end else begin
        if (wdg_active) begin
            // EVERY index advance rides the handshake. Stepping the index while the FIFO could
            // not take the byte is exactly how the report's tail was lost.
            if (dbg_uart_accept) begin
                if (wdg_idx == WDG_MSG_LAST) begin
                    wdg_active <= 1'b0;
                    // The PRF record follows with no gap: the three are ONE report and the
                    // trigger's `hold` covers all three, so a counter delta cannot straddle two.
                    prf_active <= 1'b1;
                    prf_idx <= 9'd0;
                end else begin
                    wdg_idx <= wdg_idx + 9'd1;
                end
            end
        end else if (prf_active) begin
            if (dbg_uart_accept) begin
                if (prf_idx == 9'd255) begin
                    prf_active <= 1'b0;               // pc9821_perf_msg's PRF_MSG_LEN - 1
                    gfx_active <= 1'b1;
                    gfx_idx <= 7'd0;
                end else begin
                    prf_idx <= prf_idx + 9'd1;
                end
            end
        end else if (gfx_active) begin
            if (dbg_uart_accept) begin
                if (gfx_idx == 7'd99) gfx_active <= 1'b0;   // pc9821_gfx_msg's GFX_MSG_LEN - 1
                else gfx_idx <= gfx_idx + 7'd1;
            end
        end else if (wdg_start) begin
            // The trigger is combinational and asserts for exactly the cycle its condition holds,
            // which is the cycle the counters were reset, so the report starts from index 0 in the
            // cycle after this one.
            wdg_active <= 1'b1;
            wdg_idx <= 9'd0;
        end
    end
end

endmodule

`default_nettype wire
