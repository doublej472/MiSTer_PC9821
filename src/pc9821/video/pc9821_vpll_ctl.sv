// The video PLL's two configurations: the 24 kHz and 31 kHz dot clocks.
//
// The video clock is twice the dot clock the raster runs on (pc9821_video_out says why), and the dot
// clock follows the guest: 0x09A8 bit 0 switches the machine to its separate 31 kHz oscillator
// (docs/probes/CRT31K.TXT). So the PLL moves between (pc9821_vclk_pkg has the numbers and the capture):
//   24 kHz   2 x 400/19 MHz      = 42.105 263 MHz   M 16, K 0            (VCO 800 MHz)
//   31 kHz   2 x 25.168 007 MHz  = 50.336 015 MHz   M 19, K 0x20B00000   (VCO 956.38 MHz)
// both with N bypassed (the 50 MHz reference is the PFD) and C0 = 19. There is no 15 kHz TV converter
// (no composite/S-Video output), so there is no third configuration to select: a 31 kHz raster always leaves on the native path (pc9821_video_out).
//
// A FRACTIONAL-N PLL. No integer M/N/C from 50 MHz comes within 54 ppm of the captured 25.168 MHz with
// the PFD in range (M 151 / N 10 / C 30 is the closest, at the 5 MHz PFD floor), so the PLL is
// generated in fractional mode (tools/profile/vpll_template.v) as the framework's own HDMI PLL is
// (sys/pll_hdmi). The wizard generates it at the 31 kHz configuration (the fastest clock a build
// runs, so the fitter times the video domain at 19.87 ns) with N bypassed, C0 = 19, charge pump 20 /
// bandwidth 4000 (rtl/vpll/vpll_0002.v `pll_cp_current(20)`, `pll_bwctrl(4000)`, the same the integer
// PLL had at 800 and 1000 MHz), and every reconfiguration writes N (bypass), M and K, so the output is
// 50 MHz x (M + K/2^32) / C0 whatever M/N the fitter re-factors at placement (a fit has placed
// the integer PLL at N 2; a fractional PLL's PFD is the reference, and these writes put it there
// either way). C0 is 19 in every setting and is left as generated (the fit report's PLL Usage Summary
// confirms 19). The top drives this through the framework's cut-down core
// (sys/pll_cfg/pll_cfg_hdmi.v), which takes exactly these writes. The PFD stays 50 MHz and M stays
// within 16..19, so the loop settings the fitter chose hold for both.
//
// Altera PLL reconfiguration register map (Cyclone V altera_pll_reconfig, as the framework's
// pll_cfg_hdmi drives it and Main_MiSTer programs the HDMI PLL): address 2 = start, 3 = N counter,
// 4 = M counter, 7 = the M counter's 32-bit fractional value K. A counter word is
// {odd[17], bypass[16], high[15:8], low[7:0]}.
//
// Until the PLL has relocked and stayed locked for SETTLE clocks, `busy` holds the video side's FIFO
// in reset (pc9821_video_out flushes and re-primes). The raster on clk_sys switches its dot rate
// at once (pc9821_dot_ce), so nothing guest-visible waits for this.
`timescale 1ns / 1ps

module pc9821_vpll_ctl #(
	parameter integer SETTLE = 4096                 // clk cycles of stable lock before use
) (
	input             clk,                          // the reconfiguration core's mgmt_clk (CLK_50M)
	input             want_31k,                     // level, any domain: 0x09A8 bit 0
	input             pll_locked,                   // the video PLL's locked, asynchronous
	input             mgmt_waitrequest,
	output wire        mgmt_write,
	output wire  [5:0] mgmt_address,
	output wire [31:0] mgmt_writedata,
	output wire        vclk_31,                     // the configuration the PLL is in or going to
	output wire        busy                         // the video clock is not usable
);

import pc9821_vclk_pkg::*;

function automatic [31:0] counter_word(input int unsigned n);
	// {odd, bypass, high, low}: high = ceil(n/2), low = floor(n/2); n = 1 is bypass.
	if (n <= 1) counter_word = 32'h0001_0000;
	else        counter_word = {14'd0, n[0], 1'b0, 8'((n + 1) / 2), 8'(n / 2)};
endfunction

localparam [31:0] N_WORD   = 32'h0001_0000;                     // N bypassed: the PFD is 50 MHz
localparam [31:0] M24_WORD = counter_word(VPLL_M24);             // 0x0808
localparam [31:0] M31_WORD = counter_word(VPLL_M31);             // 0x20A09

localparam [2:0] S_IDLE = 3'd0, S_WRITE_N = 3'd1, S_WRITE_M = 3'd2, S_WRITE_K = 3'd3,
                 S_START = 3'd4, S_SETTLE = 3'd5;

// Power-up values, no reset: the module's state is the PLL's, and the PLL is not reset with the
// guest (an OSD reset must not take the picture down; a guest reset clears 0x09A8 and so moves it).
// Every power-up value sits on an internal register and the ports are driven from them: Quartus
// ignores a power-up value on an output port (docs/policies.md, the power-up rule).
/* verilator lint_off PROCASSINIT */
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [1:0] lock_s = 2'b00;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [1:0] c31_s  = 2'b00;
reg [2:0]  state  = S_SETTLE;
reg [$clog2(SETTLE+1)-1:0] settle = '0;
reg        known  = 1'b0;                            // the PLL is in a configuration we wrote
reg        mgmt_write_r     = 1'b0;
reg  [5:0] mgmt_address_r   = 6'd0;
reg [31:0] mgmt_writedata_r = 32'd0;
reg        vclk_31_r        = 1'b1;                  // the generated configuration
reg        busy_r           = 1'b1;
/* verilator lint_on PROCASSINIT */
assign mgmt_write     = mgmt_write_r;
assign mgmt_address   = mgmt_address_r;
assign mgmt_writedata = mgmt_writedata_r;
assign vclk_31        = vclk_31_r;
assign busy           = busy_r;

wire want_c31 = c31_s[1];

always @(posedge clk) begin
	lock_s <= {lock_s[0], pll_locked};
	c31_s  <= {c31_s[0], want_31k};
	case (state)
		S_IDLE: begin
			if (!known || want_c31 != vclk_31) begin
				vclk_31_r        <= want_c31;
				busy_r           <= 1'b1;
				known            <= 1'b1;
				mgmt_write_r     <= 1'b1;
				mgmt_address_r   <= 6'd3;
				mgmt_writedata_r <= N_WORD;
				state            <= S_WRITE_N;
			end else if (!lock_s[1]) begin           // lost lock: hold the video side until it is back
				busy_r <= 1'b1;
				settle <= '0;
				state  <= S_SETTLE;
			end else
				busy_r <= 1'b0;                         // settled, and the configuration asked for
		end
		S_WRITE_N: if (!mgmt_waitrequest) begin
			mgmt_address_r   <= 6'd4;
			mgmt_writedata_r <= vclk_31 ? M31_WORD : M24_WORD;
			state            <= S_WRITE_M;
		end
		S_WRITE_M: if (!mgmt_waitrequest) begin
			mgmt_address_r   <= 6'd7;
			mgmt_writedata_r <= vclk_31 ? VPLL_K31 : VPLL_K24;
			state            <= S_WRITE_K;
		end
		S_WRITE_K: if (!mgmt_waitrequest) begin
			mgmt_address_r   <= 6'd2;
			mgmt_writedata_r <= 32'd0;
			state            <= S_START;
		end
		S_START: if (!mgmt_waitrequest) begin
			mgmt_write_r <= 1'b0;
			settle       <= '0;
			state        <= S_SETTLE;
		end
		default: begin                               // S_SETTLE
			if (mgmt_waitrequest || !lock_s[1]) settle <= '0;
			else if (settle == SETTLE[$clog2(SETTLE+1)-1:0])
				state <= S_IDLE;                      // IDLE releases busy unless a change is pending
			else settle <= settle + 1'd1;
		end
	endcase
end

endmodule
