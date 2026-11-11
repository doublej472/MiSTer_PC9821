// The OSD "Aspect ratio" field into video_freak's ARX/ARY, on clk_vid.
//
// OPTION 0, "Original", IS THE NEC MONITOR'S SHAPE, which depends on the line count. NEC's
// display specification sheets (support.nec-lavie.jp/support/product/data/spec/dsp/dNNN-1.html)
// give each scan mode's display area (表示面積, mm), and the dots are square in every mode:
//   d077 PC-KD854 (640x400, 24.83 kHz):            表示面積 240*150             -> 16:10
//   d059 PC-KD1522 (24/31 kHz, 400 / 480 lines):   表示面積 260*163 / 260*195   -> 16:10 / 4:3
//   d087 PC-KD871 (200/400 lines):                 "表示面積200/400ライン:240*150" -> 16:10 both
// so a 400-line picture (24 or 31 kHz, and the 200-line mode, which fills the same area) is
// 16:10 and a 480-line picture is 4:3, the same tube's width with 80 more lines. DOSBox-X draws
// PC-98 video by the same rule (its commit 9dd43b4, "VGA: Maintain a 16:10 aspect ratio for
// 400-line PC-98 video modes": `if (height >= 480) scanfield_ratio = (4.0/3.0) / scanratio;
// else scanfield_ratio = (16.0/10.0) / scanratio;`).
//
// THE LINE COUNT IS MEASURED HERE, ON clk_vid, from the picture video_freak itself receives
// (de/vs after the cleaner and gamma stages), counted the way video_freak counts its vsize: one
// line per falling edge of DE on a pixel enable, a frame ended by the rising edge of VS (the
// cleaner's syncs are active high). That is the displayed height whatever produced it - the
// master/slave union pc9821_crtc draws (the BIOS 640x480 block runs the master at AL 475 and the
// slave at AL 480), the 31 kHz 400-line raster, and the analog doubler, whose picture is the same
// image at twice the lines (dbl: the doubler's clk_vid `doubling` level, so the count is halved).
// Nothing crosses a clock domain for it (docs/clock-domains.md, V4).
//
// IT CHANGES ONLY AT A FRAME BOUNDARY, and only after two whole frames agree. video_freak takes
// ARX/ARY on every clock (sys/video_freak.sv: `arx <= ARX;`, outside any VS test), so the value
// must not move mid-frame; and a frame cut short by a PLL relock flush (pc9821_video_out empties
// its FIFO, DE stays low) must not flip the shape for one frame.
//
// OPTIONS 1-3 are unchanged: 1 "Full Screen" is the freescale sentinel 3:0, 2/3 are 1:0 and 2:0,
// the ARC1/ARC2 values sys_top substitutes (z486_mister.sv says why 3:0 and not 0:0).
`timescale 1ns / 1ps

module pc9821_aspect (
	input             clk,      // clk_vid
	input             ce,       // the picture's pixel enable (video_freak's CE_PIXEL)
	input             vs,       // active high (the cleaner's output, as video_freak takes it)
	input             de,
	input             dbl,      // clk_vid level: the analog doubler is running (lines x2)
	input       [2:0] ar,       // the OSD field, status[23:22] zero-extended
	output     [11:0] arx,
	output     [11:0] ary
);

// THE THRESHOLD: 4:3 from 480 displayed lines up (the NEC sheets' 480-line area; DOSBox-X's
// `height >= 480`), 16:10 below.
localparam [11:0] TALL_LINES = 12'd480;

/* verilator lint_off PROCASSINIT */   // power-up values on internal registers, no reset
reg        de_q = 1'b0, vs_q = 1'b0;
reg [11:0] lcnt = '0;        // lines of the frame in progress
reg        cand = 1'b0;      // the previous whole frame's class (1 = 480-line)
reg        tall = 1'b0;      // the class two frames agreed on: power-up 400-line (the boot raster)
reg [11:0] arx_r = 12'd16, ary_r = 12'd10;
/* verilator lint_on PROCASSINIT */

wire de_fall = ce & de_q & ~de;
wire vs_rise = ce & vs & ~vs_q;
// The two events of this block are de_fall (one line ends) and vs_rise (the frame ends); each has
// this block as its one consumer. COINCIDENT (R4): a line that ends on the frame's last pixel
// enable belongs to the frame that is ending, so the closing count is lcnt + de_fall and the new
// frame starts at 0. tb_pc9821_aspect fires the two together.
wire [11:0] lines  = lcnt + {11'd0, de_fall};
wire [11:0] rows   = dbl ? {1'b0, lines[11:1]} : lines;
wire        cls    = (rows >= TALL_LINES);
wire [11:0] lcnt_n = vs_rise ? 12'd0 : (lcnt + {11'd0, (de_fall && lcnt != 12'hFFF)});
wire        tall_n = (vs_rise && cls == cand) ? cls : tall;

always @(posedge clk) begin
	if (ce) begin
		de_q <= de;
		vs_q <= vs;
	end
	lcnt <= lcnt_n;
	if (vs_rise) cand <= cls;
	tall <= tall_n;
	// Registered from the agreed class and the OSD field (quasi-static, V4).
	arx_r <= (ar == 3'd0) ? (tall ? 12'd4 : 12'd16) : (ar == 3'd1) ? 12'd3 : (12'(ar) - 12'd1);
	ary_r <= (ar == 3'd0) ? (tall ? 12'd3 : 12'd10) : 12'd0;
end

assign arx = arx_r;
assign ary = ary_r;

endmodule
