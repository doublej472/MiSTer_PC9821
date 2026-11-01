// A diagnostic monitor of the analog picture the core emits (VIDEO_MON_EN builds only): what the
// framework's VGA path receives on CLK_VIDEO, measured on the chip, one ASCII line per window on
// the debug UART pin (115200 8N1, /dev/ttyS1 on the HPS).
//
// The window is VCLK_HZ clk_vid clocks: one second only while clk_vid runs at VCLK_HZ. The top
// passes the 31 kHz rate (VIDEO_CLK_HZ, 50.336 MHz), so on the 24 kHz clock (42.105 MHz) a window
// is 1.195 s and N counts about 67 frames rather than 56. Per window, min and max of:
//   L  line length, clocks between hsync leading edges (sync active low)
//   H  hsync width, clocks
//   F  lines per frame (hsync leading edges between vsync leading edges)
//   V  vsync width, lines (hsync leading edges while vsync is low)
//   O  the vsync leading edge's offset from the last hsync leading edge, clocks
// and the counts of N frames, E crossing-FIFO events (pc9821_video_out flush/re-centre/underflow)
// and D samples with DE high inside hsync or vsync. All values hex:
//   "VM L0350-0350 H040-040 F370-370 V10-10 O001-001 N38 E0000 D0000\r\n"
// The record is latched on clk_vid at the window's end and crosses as a toggle; its fields then
// stay still for a second, so the clk_sys serializer reads them as quasi-static values.
`timescale 1ns / 1ps

module pc9821_video_mon #(
	parameter integer VCLK_HZ = 42_105_263,
	parameter integer SYS_HZ  = 90_000_000
) (
	input        clk_vid,
	input        ce,
	input        hs,                                // active low
	input        vs,                                // active low
	input        de,
	input        fifo_ev,                           // one clk_vid pulse per crossing-FIFO event
	input        clk_sys,
	output       tx
);

/* verilator lint_off PROCASSINIT */   // power-up values: a diagnostic with no reset
// ================================ clk_vid: measure ================================
reg        hs_q = 1'b1, vs_q = 1'b1;
reg [15:0] lcnt = '0, hcnt = '0, ocnt = '0;
reg [11:0] fl = '0, vw = '0;
reg [15:0] l_lo = 16'hFFFF, l_hi = '0, h_lo = 16'hFFFF, h_hi = '0, o_lo = 16'hFFFF, o_hi = '0;
reg [11:0] f_lo = 12'hFFF, f_hi = '0, v_lo = 12'hFFF, v_hi = '0;
reg [7:0]  nfr = '0;
reg [15:0] nev = '0, nde = '0;
reg [31:0] win = '0;
reg        have_l = 1'b0, have_f = 1'b0;
// The latched record (the formatter prints only the digits each field needs: the top bits of the
// sync widths, the offset and the vsync width are unused by design)
/* verilator lint_off UNUSEDSIGNAL */
reg [15:0] r_l_lo = '0, r_l_hi = '0, r_h_lo = '0, r_h_hi = '0, r_o_lo = '0, r_o_hi = '0, r_nev = '0, r_nde = '0;
reg [11:0] r_f_lo = '0, r_f_hi = '0, r_v_lo = '0, r_v_hi = '0;
reg [7:0]  r_nfr = '0;
/* verilator lint_on UNUSEDSIGNAL */
reg        r_tog = 1'b0;

wire hs_fall = ce & hs_q & ~hs;
wire hs_rise = ce & ~hs_q & hs;
wire vs_fall = ce & vs_q & ~vs;
wire vs_rise = ce & ~vs_q & vs;
wire win_end = (win == 32'(VCLK_HZ - 1));

always @(posedge clk_vid) begin
	if (ce) begin
		hs_q <= hs;
		vs_q <= vs;
	end
	lcnt <= hs_fall ? 16'd1 : (&lcnt ? lcnt : lcnt + 1'd1);
	hcnt <= hs_fall ? 16'd1 : (~hs & ~&hcnt) ? hcnt + 1'd1 : hcnt;
	ocnt <= hs_fall ? 16'd1 : (&ocnt ? ocnt : ocnt + 1'd1);
	win  <= win_end ? '0 : win + 1'd1;
	if (win_end) begin
		{r_l_lo, r_l_hi, r_h_lo, r_h_hi, r_o_lo, r_o_hi} <= {l_lo, l_hi, h_lo, h_hi, o_lo, o_hi};
		{r_f_lo, r_f_hi, r_v_lo, r_v_hi, r_nfr, r_nev, r_nde} <= {f_lo, f_hi, v_lo, v_hi, nfr, nev, nde};
		r_tog <= ~r_tog;
		l_lo <= 16'hFFFF; l_hi <= '0; h_lo <= 16'hFFFF; h_hi <= '0; o_lo <= 16'hFFFF; o_hi <= '0;
		f_lo <= 12'hFFF;  f_hi <= '0; v_lo <= 12'hFFF;  v_hi <= '0;
		nfr <= '0; nev <= '0; nde <= '0;
	end else begin
		if (hs_fall && have_l) begin
			if (lcnt < l_lo) l_lo <= lcnt;
			if (lcnt > l_hi) l_hi <= lcnt;
		end
		if (hs_rise) begin
			if (hcnt < h_lo) h_lo <= hcnt;
			if (hcnt > h_hi) h_hi <= hcnt;
		end
		if (vs_fall) begin
			if (ocnt < o_lo) o_lo <= ocnt;
			if (ocnt > o_hi) o_hi <= ocnt;
			if (have_f) begin
				if (fl < f_lo) f_lo <= fl;
				if (fl > f_hi) f_hi <= fl;
				nfr <= nfr + 1'd1;
			end
		end
		if (vs_rise) begin
			if (vw < v_lo) v_lo <= vw;
			if (vw > v_hi) v_hi <= vw;
		end
		if (fifo_ev && ~&nev) nev <= nev + 1'd1;
		if (ce && de && (~hs || ~vs) && ~&nde) nde <= nde + 1'd1;
	end
	if (hs_fall) have_l <= 1'b1;
	if (vs_fall) begin
		have_f <= 1'b1;
		fl     <= hs_fall ? 12'd1 : 12'd0;
	end else if (hs_fall) fl <= fl + 1'd1;
	if (vs_fall) vw <= hs_fall ? 12'd1 : 12'd0;
	else if (hs_fall && ~vs) vw <= vw + 1'd1;
end

// ================================ clk_sys: format and send ================================
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [2:0] tog_s = '0;
always @(posedge clk_sys) tog_s <= {tog_s[1:0], r_tog};
wire go = tog_s[2] ^ tog_s[1];

// The line, one character per index: literals and hex nibbles of the latched record.
function automatic [7:0] hx(input [3:0] n);
	return (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h37 + {4'd0, n});
endfunction
reg [6:0] idx = 7'd127;
reg [7:0] ch;
always @(*) begin
	case (idx)
		7'd0: ch = "V"; 7'd1: ch = "M"; 7'd2: ch = " ";
		7'd3: ch = "L"; 7'd4: ch = hx(r_l_lo[15:12]); 7'd5: ch = hx(r_l_lo[11:8]); 7'd6: ch = hx(r_l_lo[7:4]); 7'd7: ch = hx(r_l_lo[3:0]);
		7'd8: ch = "-"; 7'd9: ch = hx(r_l_hi[15:12]); 7'd10: ch = hx(r_l_hi[11:8]); 7'd11: ch = hx(r_l_hi[7:4]); 7'd12: ch = hx(r_l_hi[3:0]);
		7'd13: ch = " "; 7'd14: ch = "H"; 7'd15: ch = hx(r_h_lo[11:8]); 7'd16: ch = hx(r_h_lo[7:4]); 7'd17: ch = hx(r_h_lo[3:0]);
		7'd18: ch = "-"; 7'd19: ch = hx(r_h_hi[11:8]); 7'd20: ch = hx(r_h_hi[7:4]); 7'd21: ch = hx(r_h_hi[3:0]);
		7'd22: ch = " "; 7'd23: ch = "F"; 7'd24: ch = hx(r_f_lo[11:8]); 7'd25: ch = hx(r_f_lo[7:4]); 7'd26: ch = hx(r_f_lo[3:0]);
		7'd27: ch = "-"; 7'd28: ch = hx(r_f_hi[11:8]); 7'd29: ch = hx(r_f_hi[7:4]); 7'd30: ch = hx(r_f_hi[3:0]);
		7'd31: ch = " "; 7'd32: ch = "V"; 7'd33: ch = hx(r_v_lo[7:4]); 7'd34: ch = hx(r_v_lo[3:0]);
		7'd35: ch = "-"; 7'd36: ch = hx(r_v_hi[7:4]); 7'd37: ch = hx(r_v_hi[3:0]);
		7'd38: ch = " "; 7'd39: ch = "O"; 7'd40: ch = hx(r_o_lo[11:8]); 7'd41: ch = hx(r_o_lo[7:4]); 7'd42: ch = hx(r_o_lo[3:0]);
		7'd43: ch = "-"; 7'd44: ch = hx(r_o_hi[11:8]); 7'd45: ch = hx(r_o_hi[7:4]); 7'd46: ch = hx(r_o_hi[3:0]);
		7'd47: ch = " "; 7'd48: ch = "N"; 7'd49: ch = hx(r_nfr[7:4]); 7'd50: ch = hx(r_nfr[3:0]);
		7'd51: ch = " "; 7'd52: ch = "E"; 7'd53: ch = hx(r_nev[15:12]); 7'd54: ch = hx(r_nev[11:8]); 7'd55: ch = hx(r_nev[7:4]); 7'd56: ch = hx(r_nev[3:0]);
		7'd57: ch = " "; 7'd58: ch = "D"; 7'd59: ch = hx(r_nde[15:12]); 7'd60: ch = hx(r_nde[11:8]); 7'd61: ch = hx(r_nde[7:4]); 7'd62: ch = hx(r_nde[3:0]);
		7'd63: ch = 8'h0D; 7'd64: ch = 8'h0A;
		default: ch = 8'h00;
	endcase
end

wire       busy;
reg        wr = 1'b0;
reg  [7:0] data = '0;
always @(posedge clk_sys) begin
	wr <= 1'b0;
	if (go) idx <= 7'd0;
	else if (idx <= 7'd64 && !busy && !wr) begin
		data <= ch;
		wr   <= 1'b1;
		idx  <= idx + 1'd1;
	end
end
/* verilator lint_on PROCASSINIT */

uart_tx_V2 #(.clk_freq(SYS_HZ), .uart_freq(115200)) tx_i (
	.clk(clk_sys), .din(data), .wr_en(wr), .tx_busy(busy), .tx_p(tx)
);

endmodule
