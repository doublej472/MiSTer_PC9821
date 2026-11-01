// SPDX-License-Identifier: BSD-2-Clause
// Copyright (c) 2014, Aleksander Osman; Copyright (C) 2017-2020 Alexey Melnikov;
// and the ao486_MiSTer contributors. From ao486_MiSTer rtl/soc/cdda.v
// (https://github.com/MiSTer-devel/ao486_MiSTer). Licence text: NOTICE, part 4.

/* verilator lint_off PROCASSINIT */   // The CLK_AUDIO half has no reset, so its power-up state IS
                                       // the seeds below: each of them is a
                                       // declaration with an initial value that the procedural code
                                       // then assigns, which is exactly this warning's shape.
/* verilator lint_off SIMILARNAME */   // Vendor naming, upstream ao486's: `audio_l`/`audio_r`
                                       // overlap AUDIO_L/AUDIO_R in case only. Renaming them is an
                                       // edit to a vendored file for no behavioural gain.
/* verilator lint_off IMPLICITSTATIC */ // The function-local regs (old_clk, clk_d1/clk_d2,
                                       // old_wr/rd_req) are upstream's, and their lifetime is
                                       // static in every tool this builds on; `automatic` would
                                       // change the vendor copy for no behavioural gain.
module cdda #(parameter CLK_AUDIO_RATE, parameter RING_WORDS = 6144)
(
	input             CLK,
	output reg        CDDA_REQ,
	// LOCAL CHANGE (PC-9821 core): read-ahead. CDDA_REQ4 says the ring has room for four whole
	// sectors (the drive then fetches four in one host request), CDDA_PLAYED pulses once per 588
	// samples taken out of the ring (one sector's worth reached the speakers: the drive's played
	// position), and CDDA_FLUSH (one CLK cycle, from the drive's player) empties the ring at once.
	output reg        CDDA_REQ4 = 0,
	output reg        CDDA_PLAYED = 0,
	input             CDDA_FLUSH,
	input             CDDA_WR,
	input      [31:0] CDDA_DATA,
	input       [3:0] VOLUME_L,
	input       [3:0] VOLUME_R,

	input             CLK_AUDIO,
	output reg        AUDIO_CE = 0,
	output reg [15:0] AUDIO_L = 0,
	output reg [15:0] AUDIO_R = 0
);

localparam SECTOR_SIZE  = 2352*8/32;
// LOCAL CHANGE (PC-9821 core): the ring holds RING_WORDS stereo samples (6144 = 139 ms, 10.4
// sectors) instead of ao486's 2048 (46 ms). Its occupancy is filled_cnt, which also decides empty
// and full, so the size need not be a power of two.
localparam BUFFER_SIZE  = RING_WORDS;
localparam BUFFER_WIDTH = $clog2(BUFFER_SIZE);

// The accumulator's step (88200) and wrap threshold (CLK_AUDIO_RATE) share a common factor G
// (600 at 24.576 MHz), and the counter only ever holds multiples of G (it starts at 0, adds 88200
// and subtracts CLK_AUDIO_RATE), so it runs in units of G: step 147, threshold 40960, 16 bits
// instead of 32. The toggle instants are identical clock for clock.
function automatic integer gcd(input integer a, input integer b);
	integer x, y, t;
	begin
		x = a; y = b;
		while (y != 0) begin t = x % y; x = y; y = t; end
		gcd = x;
	end
endfunction
localparam integer DIV_G    = gcd(CLK_AUDIO_RATE, 88200);
localparam integer DIV_STEP = 88200 / DIV_G;
localparam integer DIV_WRAP = CLK_AUDIO_RATE / DIV_G;
localparam integer CNT_W    = $clog2(DIV_WRAP + DIV_STEP);
/* verilator lint_off WIDTHTRUNC */   // CNT_W = $clog2(DIV_WRAP+DIV_STEP) bits hold both values, so
                                      // narrowing the 32-bit integers drops only zero bits
localparam [CNT_W-1:0] DIV_STEP_V = DIV_STEP;
localparam [CNT_W-1:0] DIV_WRAP_V = DIV_WRAP;
/* verilator lint_on WIDTHTRUNC */

// Power-up state: the CLK_AUDIO domain has no reset and
// the seeds below are the whole of its initialisation. Unseeded, the fractional
// divider X-locks in 4-state sim (clk_44100_cnt <= X + 88200 = X and the wrap
// compare is X) and AUDIO_CE/AUDIO_L/AUDIO_R never resolve; the ring pointers X
// poison buffer_q's read of the (deliberately unreset) ring array. Seeded: the
// divider starts at 0 and AUDIO_CE pulses at the divided rate from the first
// wraps; the ring starts empty (read_addr == write_addr) so the drain emits
// silence until the first CDDA_WR.
reg         clk_44100 = 0;
reg  [CNT_W-1:0] clk_44100_cnt = 0;
// 88200 = 2 x 44100, the accumulator step that makes CLK_AUDIO_RATE (24576000, the wrap
// threshold and the named side of this arithmetic) the sample rate: the counter adds a toggle
// period's worth per CLK_AUDIO cycle, so clk_44100 toggles every CLK_AUDIO_RATE/88200 = 278.64
// CLK_AUDIO cycles (88.2 kHz) and AUDIO_CE pulses on its rising half at 44100 Hz.
wire [CNT_W-1:0] clk_44100_cnt_next = clk_44100_cnt + DIV_STEP_V;
wire [15:0] audio_l_clk_audio, audio_r_clk_audio;
reg [15:0] audio_l = 0;
reg [15:0] audio_r = 0;
// LOCAL CHANGE (PC-9821 core): the ring is stored as RING_WORDS/2048 banks of 2048 x 32 (the
// bank is the address's top bits), so each bank maps to M10K in its 2K x 5 mode: 7 blocks a bank,
// 21 for 6144 words. One 6144-deep array is mapped 8K x 1 by Quartus: 32 blocks (measured, fit
// of 5d23d3ae seed 4).
localparam NBANK = BUFFER_SIZE / 2048;
// RING_WORDS must be two to four whole banks (4096, 6144 or 8192): read_addr[BUFFER_WIDTH-1:11]
// names the bank (a reversed range below 4096 words), NBANK would drop a partial bank, and
// read_bank_q is two bits. Any other size fails elaboration on this guard, an instance of a
// module that does not exist (Quartus 17 has no elaboration-time $error).
generate if ((RING_WORDS % 2048) != 0 || RING_WORDS < 4096 || RING_WORDS > 8192) begin : g_ring_words
	cdda_RING_WORDS_must_be_4096_6144_or_8192 bad_ring_words ();
end endgenerate
wire [31:0] bank_q [0:NBANK-1];
reg   [1:0] read_bank_q = 0;            // the bank buffer_q was read from
wire [31:0] buffer_q = bank_q[read_bank_q];

cdc_vector_handshake_continuous #(
    .DATA_WIDTH(16*2)
) audio_cdc (
    .clk_in(CLK),
    .clk_out(CLK_AUDIO),
    .data_in({audio_l, audio_r}),
    .data_out({audio_l_clk_audio, audio_r_clk_audio})
);

always @(posedge CLK_AUDIO) begin
	reg old_clk = 0;

	clk_44100_cnt <= clk_44100_cnt_next;
	if (clk_44100_cnt_next >= DIV_WRAP_V) begin
		clk_44100 <= ~clk_44100;
		clk_44100_cnt <= clk_44100_cnt_next - DIV_WRAP_V;
	end

	AUDIO_CE <= 0;
	old_clk <= clk_44100;
	if(~old_clk & clk_44100) begin
		AUDIO_CE <= 1;
		AUDIO_L <= $signed(audio_l_clk_audio) >>> ~VOLUME_L;
		AUDIO_R <= $signed(audio_r_clk_audio) >>> ~VOLUME_R;
	end
end

reg        wr_req = 0;

reg [BUFFER_WIDTH-1:0] read_addr = 0, write_addr = 0;
reg   [BUFFER_WIDTH:0] filled_cnt = 0;
reg              [9:0] played_cnt = 0;   // samples of the current sector taken out (0..587)
initial filled_cnt = 0;
/* verilator lint_on PROCASSINIT */
/* verilator lint_on SIMILARNAME */

// Plain-Verilog sized constants (this .v file is not SystemVerilog under Quartus: no casts).
/* verilator lint_off WIDTHTRUNC */   // each value fits its declared width
localparam [BUFFER_WIDTH-1:0] LAST_ADDR = BUFFER_SIZE - 1;
localparam [BUFFER_WIDTH:0]   REQ1_MAX  = BUFFER_SIZE - SECTOR_SIZE - 8;
localparam [BUFFER_WIDTH:0]   REQ4_MAX  = BUFFER_SIZE - 4 * SECTOR_SIZE - 8;
localparam [BUFFER_WIDTH+1:0] RING_CAP  = BUFFER_SIZE;
/* verilator lint_on WIDTHTRUNC */
wire [BUFFER_WIDTH-1:0] write_addr_inc = (write_addr == LAST_ADDR) ? {BUFFER_WIDTH{1'b0}} : write_addr + 1'd1;
wire [BUFFER_WIDTH-1:0] read_addr_inc  = (read_addr  == LAST_ADDR) ? {BUFFER_WIDTH{1'b0}} : read_addr + 1'd1;

always @(posedge CLK) begin
	reg old_clk = 0;
	reg clk_d1 = 0, clk_d2 = 0;
	reg old_wr = 0, rd_req = 0;

	rd_req <= 0;
	wr_req <= 0;
	CDDA_PLAYED <= 0;
	// the stored write's slot is consumed either way (a flush skips it with the rest)
	if(wr_req) write_addr <= write_addr_inc;

	old_wr <= CDDA_WR;
	clk_d1 <= clk_44100;
	clk_d2 <= clk_d1;
	// the 44.1 kHz tick: both sync stages agree and the toggle just fell
	if(clk_d2 == clk_d1) old_clk <= clk_d2;

	if(CDDA_FLUSH) begin
		// The flush (one CLK cycle, from the drive's player): the ring is empty from the next
		// cycle. A write being stored this cycle (wr_req) lands at write_addr and is skipped with
		// the rest; a write edge seen this cycle is not taken; the 44.1 kHz tick in this cycle
		// sends silence; no played pulse of the old contents follows.
		read_addr  <= wr_req ? write_addr_inc : write_addr;
		filled_cnt <= 0;
		played_cnt <= 0;
		if((clk_d2 == clk_d1) && old_clk && ~clk_d2) begin
			audio_l <= 0;
			audio_r <= 0;
		end
	end
	else begin
		// A write is taken while the ring has a free slot (counting one still being stored).
		if(~old_wr && CDDA_WR && ({1'b0, filled_cnt} + {{(BUFFER_WIDTH+1){1'b0}}, wr_req}) < RING_CAP) wr_req <= 1;

		if((clk_d2 == clk_d1) && old_clk && ~clk_d2) begin
			if(filled_cnt == 0) begin
				audio_l <= 0;
				audio_r <= 0;
			end
			else begin
				rd_req <= 1;
				audio_l <= buffer_q[15:0];
				audio_r <= buffer_q[31:16];
				read_addr <= read_addr_inc;
			end
		end

		filled_cnt <= filled_cnt + wr_req - rd_req;
		// one sector's worth of samples has left the ring
		if(rd_req) begin
			if(played_cnt == 10'd587) begin played_cnt <= 0; CDDA_PLAYED <= 1; end
			else played_cnt <= played_cnt + 1'd1;
		end
	end

	// Room for one sector (588 samples) / for four (2352), with 8 samples of slack for the last
	// writes of a fetch still in the CDDA_WR -> wr_req -> filled_cnt pipeline when the drive looks.
	CDDA_REQ  <= (filled_cnt <= REQ1_MAX);
	CDDA_REQ4 <= (filled_cnt <= REQ4_MAX);
end

always @(posedge CLK) read_bank_q <= read_addr[BUFFER_WIDTH-1:11];

genvar gb;
generate for (gb = 0; gb < NBANK; gb = gb + 1) begin : g_bank
	reg [31:0] mem [0:2047];
	/* verilator lint_off PROCASSINIT */   // q's power-up value is the seed buffer_q had (above)
	reg [31:0] q = 0;
	/* verilator lint_on PROCASSINIT */
	always @(posedge CLK) begin
		q <= mem[read_addr[10:0]];
		if (wr_req && write_addr[BUFFER_WIDTH-1:11] == gb) mem[write_addr[10:0]] <= CDDA_DATA;
	end
	assign bank_q[gb] = q;
end endgenerate

/* verilator lint_on IMPLICITSTATIC */

endmodule
