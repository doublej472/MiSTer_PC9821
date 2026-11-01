// The graphics telemetry record: per-interval cycle counts that split the CPU's GVRAM and stall
// time into the paths a Touhou-style sprite frame issues, so a capture answers WHERE the frame
// budget goes.

// The four GRAPHICS counters are pc9821_gvram's, computed beside the signals they watch and passed
// here as values; the dispatch makes their owners mutually exclusive, so they are one breakdown and
// never double count. The LAST THREE live here, because their signals are pc9821_system's: DW is the
// CPU's DEVICE wait (the I/O subset of pc9821_perf_msg's MW, so MW - DW is the memory-only wait),
// and FR/IR are event counts (vsync edges and interrupt acknowledges) that turn the cycle counts
// into a per-frame or per-interrupt cost.

// THE LAYOUT IS A CONTRACT with tools/decode_telemetry.py and tools/check_telemetry_contract.py:
// "GFX", then eight 12-byte fields (a SPACE, a 2-char label, '=', 8 hex digits), then ONE LF, 100
// bytes. Every field carries its leading space and there is no CR anywhere: see on why
// every record here ends with a bare LF.

`default_nettype none

module pc9821_gfx_msg (
    input  wire        clk,
    input  wire        reset,
    input  wire [31:0] gvram_gr,  // GF_GR: cycles the GRCG owned an RMW store
    input  wire [31:0] gvram_gt,  // GF_GT: cycles the GRCG owned a TDW store
    input  wire [31:0] gvram_eg,  // GF_EG: cycles the EGC owned the access
    input  wire [31:0] gvram_pw,  // GF_PW: cycles the plain client owned a plane-window write
    input  wire        cpu_req,   // z_valid: a CPU request is outstanding (a LEVEL)
    input  wire        cpu_ack,   // z_ready: the target accepted it this cycle
    input  wire        cpu_io,    // z_io: ... and it is an I/O request, not memory
    input  wire        vsync,     // one clk_sys pulse per video frame
    input  wire        irq,       // one clk_sys pulse per interrupt acknowledge
    input  wire [15:0] wk_skips,  // the JIS row-cache walker's skipped-walk counter
    input  wire [6:0]  idx,       // 0..GFX_MSG_LEN-1, or past the record for NUL
    input  wire        snap,      // one pulse at the report's accept: latch the record's fields
    output reg  [7:0]  ch
);

    localparam [6:0] GFX_MSG_LEN = 7'd100;

    // A request outstanding and NOT accepted is the CPU waiting on its target; the I/O subset of
    // that is the DEVICE wait, so pc9821_perf_msg's MW minus this is the memory-only wait. The same
    // definition of "waiting" as the watchdog trigger's and pc9821_perf_msg's, so the three agree.
    // DW IS A PLATFORM-CYCLE COUNT: the request length grows with the OSD CPU Speed
    // throttle ratio, so like MW it is only meaningful at CPU Speed = Full (pc9821_perf_msg's
    // header states the rule and why it is documented rather than re-based). FR is a vblank
    // count and IR a count of INTA bus cycles (two per interrupt), both throttle-independent.
    reg [31:0] dw, fr, ir;
    always @(posedge clk) begin
        if (reset) begin
            dw <= 32'd0; fr <= 32'd0; ir <= 32'd0;
        end else begin
            if (cpu_req && !cpu_ack && cpu_io) dw <= dw + 32'd1;
            if (vsync)                         fr <= fr + 32'd1;
            if (irq)                           ir <= ir + 32'd1;
        end
    end

    // THE RECORD'S DIGITS ARE ONE INSTANT. This record is the report's TAIL: the 621-byte
    // report overflows the 512-entry FIFO behind it, so these bytes are paced at the UART drain
    // rate (~87 us each) while the four GVRAM path counters free-run and DW/FR/IR/WK keep
    // counting. Read live, one field's eight hex digits sample eight different times and a carry
    // crossing between two of them splices two values into a torn composite. `snap` (the
    // report's accept, pc9821_wdg_trigger's `start`) latches every field once, so the digits read
    // the held snapshot however long the emission waits and a record's fields are mutually
    // consistent. The live counters keep counting through the emission.
    reg [31:0] gr_q, gt_q, eg_q, pw_q, dw_q, fr_q, ir_q;
    reg [15:0] wk_q;
    always @(posedge clk) begin
        if (reset) begin
            gr_q <= 32'd0; gt_q <= 32'd0; eg_q <= 32'd0; pw_q <= 32'd0;
            dw_q <= 32'd0; fr_q <= 32'd0; ir_q <= 32'd0; wk_q <= 16'd0;
        end else if (snap) begin
            gr_q <= gvram_gr; gt_q <= gvram_gt; eg_q <= gvram_eg; pw_q <= gvram_pw;
            dw_q <= dw; fr_q <= fr; ir_q <= ir; wk_q <= wk_skips;
        end
    end

    /* verilator lint_off WIDTHEXPAND */   // a 4-bit nibble is zero-extended to add an ASCII base
    function [7:0] gfx_hc(input [3:0] n);
        gfx_hc = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n);
    endfunction
    /* verilator lint_on WIDTHEXPAND */

    // The 2-char label of each field, as two bytes. This is the ONE place a field's name lives on
    // the RTL side; the decoder's GFX_FIELDS table must name them in the same order, and
    // check_telemetry_contract.py holds the two together. `p == 1` is the label's first character
    // and `p == 2` its second, the positions of a label inside a field's 12 bytes.
    function [7:0] gfx_label(input [2:0] f, input [1:0] p);
        reg [15:0] l;
        begin
            l = (f == 3'd0) ? "GR" :
                (f == 3'd1) ? "GT" :
                (f == 3'd2) ? "EG" :
                (f == 3'd3) ? "PW" :
                (f == 3'd4) ? "DW" :
                (f == 3'd5) ? "FR" :
                (f == 3'd6) ? "IR" : "WK";
            gfx_label = (p == 2'd1) ? l[15:8] : l[7:0];
        end
    endfunction

    // Which field and which byte inside it `idx` names. "GFX" is bytes 0..2, then seven 12-byte runs
    // (3..14, 15..26, 27..38, 39..50, 51..62, 63..74, 75..86), then the LF at 87. `pos` is 7 bits
    // because that is what the subtraction produces: narrowing it to 4 would be a truncation the
    // lint must then be told to ignore.
    reg [2:0] fld;
    reg [6:0] pos;
    always @* begin
        fld = 3'd0;
        pos = 7'd0;
        if ((idx >= 7'd3) && (idx < 7'd99)) begin
            if      (idx < 7'd15) begin fld = 3'd0; pos = idx -  7'd3; end
            else if (idx < 7'd27) begin fld = 3'd1; pos = idx - 7'd15; end
            else if (idx < 7'd39) begin fld = 3'd2; pos = idx - 7'd27; end
            else if (idx < 7'd51) begin fld = 3'd3; pos = idx - 7'd39; end
            else if (idx < 7'd63) begin fld = 3'd4; pos = idx - 7'd51; end
            else if (idx < 7'd75) begin fld = 3'd5; pos = idx - 7'd63; end
            else if (idx < 7'd87) begin fld = 3'd6; pos = idx - 7'd75; end
            else                  begin fld = 3'd7; pos = idx - 7'd87; end
        end
    end

    reg [31:0] val;
    always @* begin
        case (fld)
            // The fields read the SNAPSHOT latched at the report's accept (see the block
            // above): one instant for every field's eight digits.
            3'd0:    val = gr_q;
            3'd1:    val = gt_q;
            3'd2:    val = eg_q;
            3'd3:    val = pw_q;
            3'd4:    val = dw_q;
            3'd5:    val = fr_q;
            3'd6:    val = ir_q;
            default: val = {16'd0, wk_q};
        endcase
    end

    // pos 4..11 are the eight hex digits, MOST significant first: pos 4 -> nibble 7, pos 11 ->
    // nibble 0. Stated as a case rather than arithmetic so the width of every slice is explicit.
    reg [3:0] nib;
    always @* begin
        case (pos)
            7'd4:    nib = val[31:28];
            7'd5:    nib = val[27:24];
            7'd6:    nib = val[23:20];
            7'd7:    nib = val[19:16];
            7'd8:    nib = val[15:12];
            7'd9:    nib = val[11:8];
            7'd10:   nib = val[7:4];
            default: nib = val[3:0];
        endcase
    end

    always @* begin
        if (idx >= GFX_MSG_LEN) begin
            ch = 8'h00;                       // past the record: NUL, as the watchdog's own default
        end else begin
            case (idx)
                7'd0:  ch = "G";
                7'd1:  ch = "F";
                7'd2:  ch = "X";
                GFX_MSG_LEN - 1: ch = 8'h0A;      // ONE LF: see the header
                default: begin
                    if      (pos == 7'd0) ch = " ";                // the field delimiter
                    else if (pos < 7'd3)  ch = gfx_label(fld, pos[1:0]);
                    else if (pos == 7'd3) ch = "=";
                    else                  ch = gfx_hc(nib);
                end
            endcase
        end
    end

endmodule

`default_nettype wire
