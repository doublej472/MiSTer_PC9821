// The video PLL's two configurations: the 24 kHz and 31 kHz dot clocks.
//
// The video clock is twice the dot clock the raster runs on (pc9821_video_out says why), and the dot
// clock follows the guest: 0x09A8 bit 0 switches the machine to its separate 31 kHz oscillator
// (docs/probes/CRT31K.TXT). So the PLL moves between (pc9821_vclk_pkg has the numbers, the capture
// and why each fraction sits inside the fractional-N PLL's legal 0.05..0.95):
//   24 kHz   50 MHz x (20 + 0x35E5_0000/2^32) / 24 = 42.105 261 MHz   (VCO 1010.53 MHz)
//   31 kHz   50 MHz x (24 + 0x294C_0000/2^32) / 24 = 50.336 075 MHz   (VCO 1208.07 MHz)
// both with N bypassed (the 50 MHz reference is the PFD) and C0 = 24. There is no 15 kHz TV converter (no
// composite/S-Video output), so there is no third configuration to select: a 31 kHz raster always
// leaves on the native path (pc9821_video_out).
//
// A FRACTIONAL-N PLL. No integer M/N/C from 50 MHz comes within 54 ppm of the captured 25.168 MHz with
// the PFD in range (M 151 / N 10 / C 30 is the closest, at the 5 MHz PFD floor), so the PLL is
// generated in fractional mode (tools/profile/vpll_template.v) as the framework's own HDMI PLL is
// (sys/pll_hdmi). The wizard generates it at the 24 kHz configuration (pc9821_vclk_pkg VPLL_GEN_31),
// the one the guest starts in, so a core load reconfigures nothing: this controller starts in the
// generated configuration and writes only when the guest asks for the other one. The SDC times the
// video domain at the faster 31 kHz period all the same (tools/profile/z486_mister.sdc.in). Charge
// pump 20 / bandwidth 4000 (rtl/vpll/vpll_0002.v `pll_cp_current(20)`, `pll_bwctrl(4000)`) are what
// the wizard picks for both settings, so they are never rewritten. Every reconfiguration writes N
// (bypass), M and K, so the output is 50 MHz x (M + K/2^32) / 24 whatever M/N the fitter
// re-factors at placement (a fractional PLL's PFD is the reference, and these writes put it there
// either way; the fits that generated it at 31 kHz placed N 1). C0 is 24 in both settings and is left as generated: the
// framework's cut-down core, which the top drives this through (sys/pll_cfg/pll_cfg_hdmi.v), writes
// a C counter write to physical counter 5 whatever counter it selects, and the fitter chooses which
// physical counter the output is.
//
// Altera PLL reconfiguration register map (Cyclone V altera_pll_reconfig, as the framework's
// pll_cfg_hdmi drives it and Main_MiSTer programs the HDMI PLL, video.cpp setPLL): address 2 = start,
// 3 = N counter, 4 = M counter, 7 = the M counter's 32-bit fractional value K. A counter word is
// {odd[17], bypass[16], high[15:8], low[7:0]}.
//
// A NEW 0x09A8 VALUE IS FOLLOWED ONLY ONCE IT HAS HELD FOR STABLE CLOCKS (the parameter says why): a
// burst of toggles that ends where it began reconfigures nothing, so the picture stays up through the
// ITF's serial transfer on 0x09A8 at every POST; while the PLL lags a real change the crossing FIFO re-centres (pc9821_video_out).
//
// Until the PLL has relocked and stayed locked for SETTLE clocks, `busy` holds the video side's FIFO
// in reset (pc9821_video_out flushes and re-primes). The raster on clk_sys switches its dot rate
// at once (pc9821_dot_ce), so nothing guest-visible waits for this.
//
// NO WAIT IS UNBOUNDED. A write the reconfiguration core does not take, or a lock that does not come
// back, within TIMEOUT clocks (5 ms, five times the Cyclone V PLL's 1 ms maximum lock time, tLOCK in
// the Cyclone V device datasheet) resets the PLL and the reconfiguration core for RST_CLKS clocks
// (`pll_rst`: the PLL's areset and the core's mgmt_reset), waits for lock again, and reprograms the
// configuration the guest wants; `busy` stays high throughout. Without it a PLL that failed to relock
// held the video side flushed, and the picture off, until the next core load. The core cannot be
// written while the PLL is unlocked (pll_cfg_hdmi holds waitrequest high then), so the reset is the
// only way back.
`timescale 1ns / 1ps

module pc9821_vpll_ctl #(
	parameter integer SETTLE = 4096,                // clk cycles of stable lock before use
	// clk cycles 0x09A8 bit 0 must hold a new value before the PLL follows it (0: at once). At every
	// POST the ITF clocks a 3-byte serial transfer out through bits 1:0 of 0x09A8, four times (the
	// Xe10's BANK4 code at F800:52C0..5326, the Xe's at F800:553E..55A4; the Xe10's retries while bit 7
	// reads 1, which it never does on the core), then writes the bit from the memory switch (F800:5395 / 55EF): 256 edges
	// of bit 0 that end where they began on a 24 kHz machine. The machine switches between two
	// oscillators there, with nothing to relock, so the burst must not take the picture down. What the
	// window has to outlast is the longest time bit 0 stays at the other value inside the burst,
	// measured on the card with the reset-sync monitor at every setting that stretches it (the
	// slowest CPU Speed, 0.5 MHz, and Xe10 I/O timing are the worst; the Xe10's last run, through
	// 16 `out 0x5F` before the final write, is the longest):
	//   Xe10 Full/Fast 31.5 us, Full/Xe10 35.7 us, 16 MHz/Xe10 48.3 us, 0.5 MHz/Xe10 1242.0 us;
	//   Xe Full/Fast 2.9 us, 0.5 MHz/Xe10 244.0 us.
	// 75 000 clocks of the 50 MHz reference = 1.5 ms: the worst run plus 20.8 %. A real 24 kHz /
	// 31 kHz switch reaches the picture 1.5 ms after the guest's write (the raster switches at once).
	parameter integer STABLE = 75_000,
	// clk cycles any write or relock may take before the PLL is reset (250 000 = 5 ms at 50 MHz).
	parameter integer TIMEOUT = 250_000,
	parameter integer RST_CLKS = 64                 // the reset pulse (1.28 us; the PLL needs 10 ns)
) (
	input             clk,                          // the reconfiguration core's mgmt_clk (CLK_50M)
	input             want_31k,                     // level, any domain: 0x09A8 bit 0
	input             pll_locked,                   // the video PLL's locked, asynchronous
	input             mgmt_waitrequest,
	output wire        mgmt_write,
	output wire  [5:0] mgmt_address,
	output wire [31:0] mgmt_writedata,
	output wire        pll_rst,                     // the PLL's rst and the core's mgmt_reset
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
localparam [31:0] M24_WORD = counter_word(VPLL_M24);             // 0x0A0A
localparam [31:0] M31_WORD = counter_word(VPLL_M31);             // 0x0C0C

localparam [2:0] S_IDLE = 3'd0, S_WRITE_N = 3'd1, S_WRITE_M = 3'd2, S_WRITE_K = 3'd3,
                 S_START = 3'd4, S_SETTLE = 3'd5, S_RESET = 3'd6;
localparam integer WDW = $clog2(TIMEOUT + 1);
localparam [WDW-1:0] WD_MAX = WDW'(TIMEOUT);

// Power-up values, no reset: the module's state is the PLL's, and the PLL is not reset with the
// guest (an OSD reset must not take the picture down; a guest reset clears 0x09A8 and so moves it).
// Every power-up value sits on an internal register and the ports are driven from them: Quartus
// ignores a power-up value on an output port (docs/policies.md, the power-up rule).
/* verilator lint_off PROCASSINIT */
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [1:0] lock_s = 2'b00;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [1:0] c31_s  = 2'b00;
reg [2:0]  state  = S_SETTLE;
reg [$clog2(SETTLE+1)-1:0] settle = '0;
reg        known  = 1'b1;                            // the PLL is in a configuration we know: the generated one
reg [$clog2(STABLE+2)-1:0] stable_n = '0;            // clocks want_c31 has differed from vclk_31
reg [WDW-1:0] wd  = '0;                              // clocks the current wait has taken
reg [$clog2(RST_CLKS+1)-1:0] rst_n = '0;
reg        mgmt_write_r     = 1'b0;
reg  [5:0] mgmt_address_r   = 6'd0;
reg [31:0] mgmt_writedata_r = 32'd0;
reg        pll_rst_r        = 1'b0;
reg        vclk_31_r        = VPLL_GEN_31[0];        // the generated configuration
reg        busy_r           = 1'b1;
/* verilator lint_on PROCASSINIT */
assign mgmt_write     = mgmt_write_r;
assign mgmt_address   = mgmt_address_r;
assign mgmt_writedata = mgmt_writedata_r;
assign pll_rst        = pll_rst_r;
assign vclk_31        = vclk_31_r;
assign busy           = busy_r;

wire want_c31 = c31_s[1];
wire waiting  = (state != S_IDLE) && (state != S_RESET);

always @(posedge clk) begin
	lock_s <= {lock_s[0], pll_locked};
	c31_s  <= {c31_s[0], want_31k};
	// Every state that waits on the core or the PLL counts; each step forward clears the count.
	wd <= (waiting && wd != WD_MAX) ? wd + 1'd1 : '0;
	if (waiting && wd == WD_MAX) begin
		// A write not taken, or no relock, in TIMEOUT: reset the PLL and the core, then reprogram.
		mgmt_write_r <= 1'b0;
		pll_rst_r    <= 1'b1;
		busy_r       <= 1'b1;
		known        <= 1'b0;
		rst_n        <= '0;
		state        <= S_RESET;
	end else case (state)
		S_IDLE: begin
			stable_n <= (known && want_c31 != vclk_31 && stable_n != STABLE[$clog2(STABLE+2)-1:0])
			            ? stable_n + 1'd1 : '0;
			if (!known || (want_c31 != vclk_31 && stable_n == STABLE[$clog2(STABLE+2)-1:0])) begin
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
			wd               <= '0;
			state            <= S_WRITE_M;
		end
		S_WRITE_M: if (!mgmt_waitrequest) begin
			mgmt_address_r   <= 6'd7;
			mgmt_writedata_r <= vclk_31 ? VPLL_K31 : VPLL_K24;
			wd               <= '0;
			state            <= S_WRITE_K;
		end
		S_WRITE_K: if (!mgmt_waitrequest) begin
			mgmt_address_r   <= 6'd2;
			mgmt_writedata_r <= 32'd0;
			wd               <= '0;
			state            <= S_START;
		end
		S_START: if (!mgmt_waitrequest) begin
			mgmt_write_r <= 1'b0;
			settle       <= '0;
			wd           <= '0;
			state        <= S_SETTLE;
		end
		S_RESET: begin
			if (rst_n == RST_CLKS[$clog2(RST_CLKS+1)-1:0]) begin
				pll_rst_r <= 1'b0;
				settle    <= '0;
				state     <= S_SETTLE;                // then IDLE reprograms (known is 0)
			end else
				rst_n <= rst_n + 1'd1;
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
