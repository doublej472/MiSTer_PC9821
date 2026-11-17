// PC-9821 GVRAM scanout line fetch and ping-pong line buffer.
//
// The scanout is a SIBLING of the CPU datapath and the engines rather than a child:
// this module only reads port B of pc9821_gvram_mem, and nothing in it can reach the
// CPU's port A or either engine.
//
// There is no vertical counter here and none is needed for the 200-line display mode: the
// line ORIGIN arrives as `scan_line_base`, which pc9821_system takes from the GDC2
// display-address decode (pc9821_gdc2's gfx_line_addr). That decode halves its line index
// in the 200-line mode, so two consecutive raster lines present the SAME base: the same GDC
// line on two raster lines. The doubling lives there, not here; the tick is still one per
// raster line. The 200-line mode's graphics/text INTERLEAVE lives HERE on the fetch side:
// `gfx_odd_line` skips the odd display line of each pair ENTIRELY - NP2kai fetches a display
// line only `if ((!(mg.liney & 1)) || (!(gdc.mode1 & 0x10)))` (vram/makegrph.c:155) - and
// that line shows text over black (vram/sdraw.mcr:199-243 p_2i), which
// pc9821_video_mixer's own `gfx_odd_line` gate draws. `line_ready` does not dip on a
// skipped line: the buffer still holds a complete (stale) line and the mixer's gate is
// what hides it.
//
// The fetch reads the M10K array DIRECTLY on port B: ONE column per clk_sys, 80 clk_sys of a
// raster line that lasts f(clk_sys) / 24.83 kHz (about 3,600 clk_sys at 90 MHz; the line rate is
// pc9821_video_out's header). There is no SDRAM burst to pace and no write-combining buffer to
// flush behind, so the fetch cannot read a stale column behind a pending write-back.
`default_nettype none

module pc9821_gvram_scan (
    input wire clk,
    input wire reset,

    // The scanout's view of the raster.
    input  wire        scan_enable,     // graphics display on
    input  wire        scan_line_tick,  // one pulse per raster line
    input  wire        scan_page,       // display page (port 0xA4)
    input  wire [14:0] scan_line_base,  // plane offset of this line's first column
    // The 200-line interleave's odd display line (MODE FF1 bit 4 and the line odd): no
    // graphics fetch for it (vram/makegrph.c:155; see the header). Sampled exactly as
    // scan_line_base is - at the line tick, and at the enable arm - because the tick at
    // the end of raster line L feeds display line L+2 (the +2 pipeline) and +2 preserves
    // parity, so this value IS the parity of the line the fetch would fill.
    input  wire        gfx_odd_line,
    input  wire [6:0]  line_rd_addr,    // column 0..79 of the displayed line
    input  wire        line_rd_sel,     // which buffer to read
    output wire [31:0] line_data,       // registered read, valid one clk later
    output wire        line_sel,        // which buffer the fetch considers displayed
    output wire        line_ready,
    // The page the line fetch is latched on (the page-coincidence probe reads it).
    output wire        scan_page_q,

    // The array's port B.
    output wire [15:0] gmb_addr,
    output wire        gmb_en,
    input  wire [31:0] gmb_dout
);

  // The scanout fetches 640 pixels / 8 = 80 four-plane columns per line.
  // SEVEN BITS, NOT EIGHT: 80 is the largest column the fetch issues and 127 is what seven bits
  // name, so the eighth bit carried no value. LINE_COLS is the bound the two counters below are
  // compared with, so the constant and their width move together.
  localparam [6:0] LINE_COLS = 7'd80;

  reg [6:0]  fetch_col;      // column being fetched (0..79)
  reg        fetch_active;
  reg [14:0] line_base_q;    // plane offset of the line being fetched
  reg        scan_page_q_r;  // the DISPLAY page the line is fetched from
  reg        fetch_req_d;    // a port-B read was issued last clk_sys
  reg [6:0]  fetch_col_d;    // the column that read was issued for
  reg        wr_sel;         // the buffer being filled (never line_sel_r)
  reg        line_sel_r;
  reg        line_ready_r;

  // The line tick is taken as an EDGE, not a level. `scan_line_tick`'s branch toggles
  // `line_sel_r`, so a producer that holds the signal high for more than one clk_sys
  // (high for the 2-3 clk_sys between pixel enables) would toggle the
  // ping-pong phase 2-3 times per line, and the net phase would be the level's
  // WIDTH mod 2. The port is documented as "one pulse per raster line"; taking the
  // edge is what makes that true whichever shape the producer sends.
  reg scan_tick_d;
  wire scan_tick = scan_line_tick & ~scan_tick_d;

  // A display ENABLE arms the fetch the cycle it rises, not at the next line tick. The
  // line tick below still owns the per-line column reset and the buffer swap; this only closes the
  // gap the tick-only arm left, where a re-enable just after a tick fetched nothing until the NEXT
  // tick and the real GDC's line was lost.
  reg scan_enable_d;
  wire scan_arm = scan_enable & ~scan_enable_d;

  // Port B: one column per clk_sys. The column's plane offset wraps inside the plane (the LOW15
  // fold), which is what lets a line run past the end of a plane. The page and the base are
  // latched at the line tick, so a later tick cannot redirect a beat still in flight - the
  // in-flight read is one clk_sys deep and belongs to the line that issued it.
  wire [14:0] fetch_off = line_base_q + {8'd0, fetch_col};
  wire fetch_req = fetch_active && (fetch_col < LINE_COLS) && !scan_tick;
  assign gmb_addr = {scan_page_q_r, fetch_off};
  assign gmb_en   = fetch_req;

  // The fill of the buffer being written is COMPLETE exactly when the last column has landed; the
  // display swap below waits on it.
  wire fill_complete = !fetch_active && !fetch_req_d;

  // The other piece of block RAM: 2 lines x 80 words x 32 bits = 1 M10K (the array is declared
  // 256 deep: its address is the 8-bit {line, column}). A simple dual-port
  // shape -- one synchronous write port and one registered read port -- so synthesis maps it to
  // a single M10K block. Its output port is what the pixel pipeline reads every dot; the array
  // itself is consulted once per column. Declared here, before the fill
  // below writes it, so no name is used above its declaration under `default_nettype none`.
  reg [31:0] line_buf [0:255];
  reg [31:0] line_q;

  always @(posedge clk) begin
    if (reset) begin
      fetch_col    <= 7'd0;
      fetch_active <= 1'b0;
      line_base_q  <= 15'd0;
      scan_page_q_r <= 1'b0;
      fetch_req_d  <= 1'b0;
      fetch_col_d  <= 7'd0;
      wr_sel       <= 1'b0;
      line_sel_r   <= 1'b0;
      line_ready_r <= 1'b0;
      scan_tick_d  <= 1'b0;
      scan_enable_d <= 1'b0;
    end else begin
      scan_tick_d   <= scan_line_tick;
      scan_enable_d <= scan_enable;

      // A line the guest has turned off is not a line the caller should sample.
      if (!scan_enable) line_ready_r <= 1'b0;

      if (scan_tick) begin
        // The display switches to the buffer the line that just ended was fetched into, and the
        // next line is fetched into the buffer just freed -- but ONLY when that line's fetch
        // finished. Holding instead repeats the previous line, which is the machine's own failure
        // mode and never a blended one.
        if (fill_complete) begin
          line_sel_r <= ~line_sel_r;
          wr_sel     <= line_sel_r;
        end
        line_base_q  <= scan_line_base;
        scan_page_q_r <= scan_page;
        fetch_col    <= 7'd0;
        // A 200-line interleave odd line is not fetched at all (vram/makegrph.c:155);
        // its buffer keeps the previous content and the mixer's gfx_odd_line gate
        // shows text over black instead of it.
        fetch_active <= scan_enable && !gfx_odd_line;
      end else if (scan_arm) begin
        // The DISP bit just came up mid-line: fetch the line the raster is on now (its base and
        // page are the address generator's current ones), instead of waiting for the next tick.
        // The buffer swap is the tick's own rule and is applied here for the same reason it is
        // there: the display must switch to the last COMPLETED buffer and the fetch must go into
        // the OTHER one (wr_sel must never be the buffer being displayed). A scan_tick in the same
        // cycle wins, and it sets exactly the same registers - and the tick one cycle later finds
        // this fetch in flight, so it does not swap a second time.
        if (fill_complete) begin
          line_sel_r <= ~line_sel_r;
          wr_sel     <= line_sel_r;
        end
        line_base_q  <= scan_line_base;
        scan_page_q_r <= scan_page;
        fetch_col    <= 7'd0;
        fetch_active <= !gfx_odd_line;
      end else if (fetch_req) begin
        fetch_col <= fetch_col + 7'd1;
        if (fetch_col == LINE_COLS - 7'd1) fetch_active <= 1'b0;
      end

      // The read issued last clk_sys lands in the column it was issued for, in the buffer that
      // was being filled then - wr_sel, which only moves at a tick that found the fill complete.
      // The last column of the line is what arms the swap above.
      fetch_req_d <= fetch_req;
      fetch_col_d <= fetch_col;
      if (fetch_req_d) begin
        line_buf[{wr_sel, fetch_col_d}] <= gmb_dout;
        if (fetch_col_d == LINE_COLS - 7'd1) line_ready_r <= 1'b1;
      end
    end
  end

  always @(posedge clk) begin
    line_q <= line_buf[{line_rd_sel, line_rd_addr}];
  end
  assign line_data    = line_q;
  assign line_sel     = line_sel_r;
  assign line_ready   = line_ready_r;
  assign scan_page_q  = scan_page_q_r;

endmodule

`default_nettype wire
