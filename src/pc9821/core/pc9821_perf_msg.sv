// The per-interval performance record: the interval itself, the CPU's memory wait, the SDRAM
// controller's accepted transactions, the GVRAM's array walk,
// the EGC/GRCG operation counts, the VISIBLE-line graphics cycles and sprite pass, and the
// page-coincidence probe, so a capture answers WHERE the time goes even when nothing is wedged.

// THE LAYOUT IS A CONTRACT with tools/decode_telemetry.py and tools/check_telemetry_contract.py:
// "PRF", then TWENTY-ONE 12-byte fields (a SPACE, a 2-char label, '=', 8 hex digits), then ONE LF,
// 256 bytes. CY is first so the line reads "over CY cycles: ..." and the denominator is never hunted
// for. The leading space delimits a field, so no field may be emitted without it, and there is no
// CR anywhere: every record here ends with a bare LF.

// CY IS THE DENOMINATOR: the trigger's window counters freeze while a record is emitted, so the
// interval is window + emission and not the nominal WDG_PERIOD (2 % low on a heartbeat, 17 % on a
// stall). GW/GC are pc9821_gvram's walk pulses: the module exports the event and the counting
// stays here. The CPU exports no L1 lookup or miss pulse, so the record has no cache fields.
//
// MW IS A PLATFORM-CYCLE COUNT, NOT A CPU-CYCLE COUNT. `cpu_req` (z_valid) is a LEVEL
// held for the whole CPU cycle, which is `k` clk_sys cycles under the OSD CPU Speed throttle, so
// MW also counts the DISABLED cycles in which the CPU is not running: it is the CPU's memory wait
// multiplied by the throttle ratio (up to ~160x at 0.5 MHz on an 80 MHz build). That contradicts
// rule 4 of src/z486/docs/throttle.md ("count CPU events, not platform cycles"), but this is a
// debug instrument, not a guest-visible rate, and re-basing it needs its own bench (MW for a
// known stall equal at Full and at 1 MHz), so it is STATED rather than changed: **MW - and the
// GFX record's DW, the I/O subset of it - is only meaningful at CPU Speed = Full.** The
// transaction counters (RD/WR/S1/S2/S3/W3) and the GVRAM/EGC/GRCG event counters are clk_sys
// event counts and do not have this defect; CY is the interval and stays the denominator.

`default_nettype none

module pc9821_perf_msg (
    input  wire       clk,
    input  wire       reset,
    input  wire       cpu_req,   // z_valid: a CPU memory request is outstanding (a LEVEL)
    input  wire       cpu_ack,   // z_ready: the memory subsystem accepted it this cycle
    input  wire       sd_valid,  // the MAIN SDRAM port presents a request
    input  wire       sd_ready,  // ... and it was accepted this cycle
    input  wire       sd_write,  // ... and that request is a write
    // The other three requester ports, as the bridge presents them back on clk_sys. Each
    // `ready` is the port's one-cycle accept, so a counter is a transaction count on exactly
    // RD/WR's rule. `valid && !ready` is the port PRESENTING and waiting for the bus, which for
    // the scanout (port 3) is the hard-deadline client's bus contention.
    input  wire       sd1_valid, // the font/glyph port presents a request
    input  wire       sd1_ready, // ... and it was accepted this cycle
    input  wire       sd2_valid, // the 86-PCM port presents a request
    input  wire       sd2_ready, // ... and it was accepted this cycle
    input  wire       sd3_valid, // the PEGC packed scanout port presents a request
    input  wire       sd3_ready, // ... and it was accepted this cycle
    input  wire       dbg_walk_start, // GVRAM one-visit array walk began (pc9821_gvram)
    input  wire       dbg_walk_cycle, // ... and one clk_sys of it was spent
    input  wire       dbg_egc_txn,    // an EGC command was accepted (pc9821_egc)
    input  wire       dbg_egc_unit,   // ... and one byte/word unit of it committed
    input  wire       dbg_grcg_store, // a GRCG RMW/TDW store was accepted (pc9821_grcg)
    input  wire       dbg_gr_owned,   // the GRCG OWNS the GVRAM this clk_sys (pc9821_gvram)
    input  wire       dbg_eg_owned,   // ... and the EGC owns it this clk_sys
    input  wire       dbg_pw_owned,   // ... and the PLAIN plane-window client owns it (a store)
    input  wire       v_active,       // the raster is on a visible line (pc9821_gdc_text)
    input  wire       vsync_edge,     // ONE pulse at the frame's vblank edge the IRQ rises on
    input  wire       dbg_access_page, // the CPU/GRCG/EGC access page (pc9821_gvram)
    input  wire       dbg_scan_page_q, // the page the scanout's line fetch is latched on
    // The CPU's LAST page fault, read LIVE into the record (gauges, like SP/AP, not counters).
    // The core latches the faulting linear address and the error code. A page fault is normal on this machine (DOS/4GW
    // demand-pages), so PA/PF name the LAST fault - which is the fatal one when the guest
    // stops immediately after it, and the reason a capture is taken then.
    input  wire [2:0] dbg_pf_code, // latched page-fault error code
    input  wire [31:0] dbg_pf_addr, // latched faulting linear address
    input  wire [8:0] idx,       // 0..PRF_MSG_LEN-1, or past the record for NUL
    input  wire       snap,      // one pulse at the report's accept: latch the record's counters
    output reg  [7:0] ch
);

    // 9 bits: the record is 256 bytes (3 + 21*12 + 1), so its length does not fit in 8.
    // `fld` is 5 bits: 21 fields need the fifth bit.
    localparam [8:0] PRF_MSG_LEN = 9'd256;

    // A request that is outstanding and NOT accepted is the CPU waiting on memory: the same
    // condition pc9821_wdg_trigger.sv treats as "not completed" (z_valid is a LEVEL held until
    // z_ready answers), so the two agree about what waiting means and there is one definition of
    // it in the tree. A transaction is counted when it is ACCEPTED (valid && ready): a burst is
    // one request, so it counts once, which is what makes RD/WR a transaction rate.
    // CY advances unconditionally: it is the one counter the trigger's freeze does not stop, which
    // is what makes it the interval rather than the window.
    reg [31:0] cy, mw, rd, wr, gw, gc, et, eu, gs, gv, ev, pd, pc;
    // The other three SDRAM ports' accept counts (S1/S2/S3) and the scanout port's
    // present-but-unaccepted cycles (W3), on the same accept rule as RD/WR.
    reg [31:0] s1, s2, s3, w3;
    // PD is a GAUGE, not a counter: pass_cnt restarts at every vblank edge and pd latches it at
    // each GRCG store, so pd is the LAST store's position in the frame - the sprite pass's
    // wall-clock. The decoder prints it as a value rather than a delta. PC is an
    // ordinary counter: one per clk_sys a GRCG store is in flight with the access page
    // EQUAL to the scanout's latched page. SP/AP are neither - they are the two page LEVELS
    // themselves, read live into the record.
    reg [31:0] pass_cnt;
    always @(posedge clk) begin
        if (reset) begin
            cy <= 32'd0; mw <= 32'd0; rd <= 32'd0; wr <= 32'd0;
            gw <= 32'd0; gc <= 32'd0;
            et <= 32'd0; eu <= 32'd0; gs <= 32'd0;
            gv <= 32'd0; ev <= 32'd0; pd <= 32'd0; pass_cnt <= 32'd0; pc <= 32'd0;
            s1 <= 32'd0; s2 <= 32'd0; s3 <= 32'd0; w3 <= 32'd0;
        end else begin
            cy <= cy + 32'd1;
            if (cpu_req && !cpu_ack) mw <= mw + 32'd1;
            if (sd_valid && sd_ready) begin
                if (sd_write) wr <= wr + 32'd1;
                else          rd <= rd + 32'd1;
            end
            if (sd1_valid && sd1_ready) s1 <= s1 + 32'd1;
            if (sd2_valid && sd2_ready) s2 <= s2 + 32'd1;
            if (sd3_valid && sd3_ready) s3 <= s3 + 32'd1;
            if (sd3_valid && !sd3_ready) w3 <= w3 + 32'd1;
            if (dbg_walk_start) gw <= gw + 32'd1;
            if (dbg_walk_cycle) gc <= gc + 32'd1;
            if (dbg_egc_txn)    et <= et + 32'd1;
            if (dbg_egc_unit)   eu <= eu + 32'd1;
            if (dbg_grcg_store) gs <= gs + 32'd1;
            // The graphics-owned cycles that landed on a VISIBLE line: the same
            // ownership pulses the graphics record's GR/GT/EG accumulate, gated by v_active.
            if (dbg_gr_owned && v_active) gv <= gv + 32'd1;
            if (dbg_eg_owned && v_active) ev <= ev + 32'd1;
            // The sprite pass's wall-clock. A store in the SAME cycle as the edge
            // belongs to the new frame and reads 0, not the whole previous frame.
            if (vsync_edge) pass_cnt <= 32'd0;
            else            pass_cnt <= pass_cnt + 32'd1;
            if (dbg_grcg_store) pd <= vsync_edge ? 32'd0 : pass_cnt;
            // The page-coincidence probe: a GVRAM store is IN FLIGHT while the access page
            // EQUALS the page the scanout's line fetch is latched on. Correct double-buffering
            // keeps the two pages opposite every cycle, so this is ZERO; a nonzero PC is stores
            // landing on the DISPLAYED page - the leak - and the two status bits SP/AP say which
            // pages.
            // THE IN-FLIGHT ARM IS ALL THREE WRITE OWNERS, and it has to be: with the GRCG's
            // alone the counter could only see a leak through GRCG stores - and Farland Story
            // draws with PLAIN window stores (its intervals move GW/GC/PW while GS/GR/GT stay
            // flat), so it would read 0 through the very leak it exists to find. A read (the plain
            // client's read arm, a TCR read) is still not counted: neither writes anything.
            if ((dbg_gr_owned || dbg_eg_owned || dbg_pw_owned) &&
                (dbg_access_page == dbg_scan_page_q)) pc <= pc + 32'd1;
        end
    end

    // THE RECORD'S DIGITS ARE ONE INSTANT. Each field's eight hex digits are eight byte
    // transfers, and the 707-byte report overflows the 512-entry FIFO behind it, so the emission
    // is paced at the UART drain rate in the tail while these counters keep counting: read live,
    // the eight digits of one field would sample eight different times and a carry crossing
    // between two of them splices two counter values into one torn composite. `snap` (the
    // report's accept, pc9821_wdg_trigger's `start`) latches every counter field once; the
    // digits then read the held snapshot however long the emission waits, so a record's fields
    // are mutually consistent and the ratios between them stay honest. The live counters keep
    // counting through the emission (CY advances regardless, as its contract states), so the
    // next interval still measures window + emission.
    reg [31:0] cy_q, mw_q, rd_q, wr_q, gw_q, gc_q,
               et_q, eu_q, gs_q, gv_q, ev_q, pd_q, pc_q;
    reg [31:0] s1_q, s2_q, s3_q, w3_q;
    always @(posedge clk) begin
        if (reset) begin
            cy_q <= 32'd0; mw_q <= 32'd0; rd_q <= 32'd0; wr_q <= 32'd0;
            gw_q <= 32'd0; gc_q <= 32'd0;
            et_q <= 32'd0; eu_q <= 32'd0; gs_q <= 32'd0;
            gv_q <= 32'd0; ev_q <= 32'd0; pd_q <= 32'd0; pc_q <= 32'd0;
            s1_q <= 32'd0; s2_q <= 32'd0; s3_q <= 32'd0; w3_q <= 32'd0;
        end else if (snap) begin
            cy_q <= cy; mw_q <= mw; rd_q <= rd; wr_q <= wr;
            gw_q <= gw; gc_q <= gc;
            et_q <= et; eu_q <= eu; gs_q <= gs;
            gv_q <= gv; ev_q <= ev; pd_q <= pd; pc_q <= pc;
            s1_q <= s1; s2_q <= s2; s3_q <= s3; w3_q <= w3;
        end
    end

    /* verilator lint_off WIDTHEXPAND */   // a 4-bit nibble is zero-extended to add an ASCII base
    function [7:0] prf_hc(input [3:0] n);
        prf_hc = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n);
    endfunction
    /* verilator lint_on WIDTHEXPAND */

    // The 2-char label of each field, as two bytes. This is the ONE place a field's name lives on
    // the RTL side; the decoder's PRF_FIELDS table must name them in the same order, and
    // check_telemetry_contract.py holds the two together. `p == 1` is the label's first character
    // and `p == 2` its second, the positions of a label inside a field's 12 bytes. Twenty-one
    // fields, so `f` is 5 bits: at 4 bits the later fields would alias onto CY..PC and nothing
    // would fail to compile.
    function [7:0] prf_label(input [4:0] f, input [1:0] p);
        reg [15:0] l;
        begin
            l = (f == 5'd0) ? "CY" :
                (f == 5'd1) ? "MW" :
                (f == 5'd2) ? "RD" :
                (f == 5'd3) ? "WR" :
                (f == 5'd4) ? "GW" :
                (f == 5'd5) ? "GC" :
                (f == 5'd6) ? "ET" :
                (f == 5'd7) ? "EU" :
                (f == 5'd8) ? "GS" :
                (f == 5'd9) ? "GV" :
                (f == 5'd10) ? "EV" :
                (f == 5'd11) ? "PD" :
                (f == 5'd12) ? "PC" :
                (f == 5'd13) ? "SP" :
                (f == 5'd14) ? "AP" :
                (f == 5'd15) ? "S1" :
                (f == 5'd16) ? "S2" :
                (f == 5'd17) ? "S3" :
                (f == 5'd18) ? "W3" :
                (f == 5'd19) ? "PF" : "PA";
            prf_label = (p == 2'd1) ? l[15:8] : l[7:0];
        end
    endfunction

    // Which field and which byte inside it `idx` names. "PRF" is bytes 0..2, then twenty-one
    // 12-byte runs (3..14, 15..26, ... 243..254), then the LF at 255. `pos` is 8 bits wide, the
    // truncated difference of the 9-bit `idx`. `fld` is 5 bits: twenty-one fields do not fit
    // in 4.
    reg [4:0] fld;
    reg [7:0] pos;
    always @* begin
        fld = 5'd0;
        pos = 8'd0;
        if ((idx >= 9'd3) && (idx < 9'd255)) begin
            if      (idx < 9'd15)  begin fld = 5'd0;  pos = 8'(idx -  9'd3); end
            else if (idx < 9'd27)  begin fld = 5'd1;  pos = 8'(idx - 9'd15); end
            else if (idx < 9'd39)  begin fld = 5'd2;  pos = 8'(idx - 9'd27); end
            else if (idx < 9'd51)  begin fld = 5'd3;  pos = 8'(idx - 9'd39); end
            else if (idx < 9'd63)  begin fld = 5'd4;  pos = 8'(idx - 9'd51); end
            else if (idx < 9'd75)  begin fld = 5'd5;  pos = 8'(idx - 9'd63); end
            else if (idx < 9'd87)  begin fld = 5'd6;  pos = 8'(idx - 9'd75); end
            else if (idx < 9'd99)  begin fld = 5'd7;  pos = 8'(idx - 9'd87); end
            else if (idx < 9'd111) begin fld = 5'd8;  pos = 8'(idx - 9'd99); end
            else if (idx < 9'd123) begin fld = 5'd9;  pos = 8'(idx - 9'd111); end
            else if (idx < 9'd135) begin fld = 5'd10; pos = 8'(idx - 9'd123); end
            else if (idx < 9'd147) begin fld = 5'd11; pos = 8'(idx - 9'd135); end
            else if (idx < 9'd159) begin fld = 5'd12; pos = 8'(idx - 9'd147); end
            else if (idx < 9'd171) begin fld = 5'd13; pos = 8'(idx - 9'd159); end
            else if (idx < 9'd183) begin fld = 5'd14; pos = 8'(idx - 9'd171); end
            else if (idx < 9'd195) begin fld = 5'd15; pos = 8'(idx - 9'd183); end
            else if (idx < 9'd207) begin fld = 5'd16; pos = 8'(idx - 9'd195); end
            else if (idx < 9'd219) begin fld = 5'd17; pos = 8'(idx - 9'd207); end
            else if (idx < 9'd231) begin fld = 5'd18; pos = 8'(idx - 9'd219); end
            else if (idx < 9'd243) begin fld = 5'd19; pos = 8'(idx - 9'd231); end
            else                   begin fld = 5'd20; pos = 8'(idx - 9'd243); end
        end
    end

    reg [31:0] val;
    always @* begin
        case (fld)
            // The counter fields read the SNAPSHOT latched at the report's accept (see the
            // block above): one instant for every field's eight digits.
            5'd0:    val = cy_q;
            5'd1:    val = mw_q;
            5'd2:    val = rd_q;
            5'd3:    val = wr_q;
            5'd4:    val = gw_q;
            5'd5:    val = gc_q;
            5'd6:    val = et_q;
            5'd7:    val = eu_q;
            5'd8:    val = gs_q;
            5'd9:    val = gv_q;
            5'd10:   val = ev_q;
            5'd11:   val = pd_q;
            5'd12:   val = pc_q;
            // SP/AP are the two page LEVELS, not counters: a 1-bit status read live into the
            // record's 32-bit field, so a capture sees the pages as they are at the read.
            5'd13:   val = {31'd0, dbg_scan_page_q};
            5'd14:   val = {31'd0, dbg_access_page};
            5'd15:   val = s1_q;
            5'd16:   val = s2_q;
            5'd17:   val = s3_q;
            5'd18:   val = w3_q;
            // PF/PA are the CPU's LAST page fault, read LIVE (gauges, like SP/AP): the code is
            // 3 bits and the address 32, so the faulting linear address is the field that names
            // WHERE the guest died.
            5'd19:   val = {29'd0, dbg_pf_code};
            5'd20:   val = dbg_pf_addr;
            default: val = 32'd0;
        endcase
    end

    // pos 4..11 are the eight hex digits, MOST significant first: pos 4 -> nibble 7, pos 11 ->
    // nibble 0. Stated as a case rather than arithmetic so the width of every slice is explicit.
    reg [3:0] nib;
    always @* begin
        case (pos)
            8'd4:    nib = val[31:28];
            8'd5:    nib = val[27:24];
            8'd6:    nib = val[23:20];
            8'd7:    nib = val[19:16];
            8'd8:    nib = val[15:12];
            8'd9:    nib = val[11:8];
            8'd10:   nib = val[7:4];
            default: nib = val[3:0];
        endcase
    end

    always @* begin
        if (idx >= PRF_MSG_LEN) begin
            ch = 8'h00;                       // past the record: NUL, as the watchdog's own default
        end else begin
            case (idx)
                9'd0:  ch = "P";
                9'd1:  ch = "R";
                9'd2:  ch = "F";
                PRF_MSG_LEN - 1: ch = 8'h0A;      // ONE LF: see the header
                default: begin
                    if      (pos == 8'd0) ch = " ";                // the field delimiter
                    else if (pos < 8'd3)  ch = prf_label(fld, pos[1:0]);
                    else if (pos == 8'd3) ch = "=";
                    else                  ch = prf_hc(nib);
                end
            endcase
        end
    end

endmodule

`default_nettype wire
