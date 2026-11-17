// PC-9821 display-programming log: a DEBUG INSTRUMENT (build_profile.py --dbg-gdc, DBG_GDC_EN).
//
// Every write the guest makes to the display-programming ports goes out on the debug UART as a
// seven-byte record (nine for the 0x19 attribute record), so a hardware session can capture what
// a game programs (the Policenauts attract demo's vertical offset) without simulating minutes of
// guest time.
//
// Record: 0xA5, type, a 16-bit millisecond time (big-endian), the raster line (pc9821_crtc's
// vline, 16 bits big-endian) the write landed on, one value byte. The graphics scanout's decode
// line is that raster line + 2 (pc9821_gdc2's two-line pipeline); a SCROLL rewritten while the
// raster is inside the display is how a raster split shows up.
//   type 0x10+n   a port write; n = 0 0x60 (GDC1 parameter), 1 0x62 (GDC1 command),
//                 2 0xA0 (GDC2 parameter), 3 0xA2 (GDC2 command), 4 0x68 (MODE FF1),
//                 5 0x6A (MODE FF2), 6 0xA4 (display page), 7 0xA6 (access page),
//                 8 0x09A8 (the 24/31 kHz select)
//   type 0x19     a text ATTRIBUTE write run (CPU writes to 0xA2000-0xA3FFF, even bytes): NINE
//                 bytes - 0xA5, 0x19, ms, the previous run's last cell (16 bits), this run's first
//                 cell (16 bits), the attribute. A run is consecutive cells (+2 bytes) written
//                 the same value; only a write that breaks the run is logged, so a fill of the
//                 whole screen is one record. Cell = row * 80 + column. (Text masks are cells,
//                 so this is how a black-reverse mask over the graphics shows up.)
//   type 0x1E     LOST: the records dropped since the last one that got out (value = count)
//   type 0x1F     ALIVE: 0x5A, at power-up and at the end of every core reset
// (LOST/ALIVE were 0x09/0x0A in the first version of this log, which are the CD log's LOST/ALIVE
// types: the unified debug-UART record table, pc9821_dbg_mux, keeps the types disjoint.)
//
// The UART carries ~11,500 bytes/s (1,640 records/s), so the stream is FILTERED to the display
// state: a GDC command byte is logged only when it is a display command - RESET (0x00), the
// display on/off pair (0x0C/0x0D, 0x05/0x6B), SYNC (0x0E/0x0F), MASTER/SLAVE (0x6E/0x6F), ZOOM
// (0x06/0x46), PITCH (0x47), CSRFORM (0x4B) or SCROLL/TEXTW (0x70-0x7F, the 16 parameter-RAM
// bytes the partitions read) - and a parameter byte only while such a command is the GDC's
// current one (NP2kai gdc_cmd.tbl: these are the commands whose parameters reach the display).
// The drawing traffic (CSRW, VECTW, WRITE, MASK...) and the text cursor are not logged. The five
// register ports are logged only when the value differs from the last one logged for that port.
//
// A write is latched and serialised a byte per cycle into a 2 KiB ring (pc9821_dbg_ring) that
// drains to the UART FIFO at its own pace. A guest I/O write is tens of cycles long, so a seven-cycle serialisation
// never overlaps the next one; a write that does find the stage busy, or a full ring, counts as
// LOST, and a LOST record follows once there is room.
`default_nettype none
// Power-up values on the log's own state (no core reset reaches the instrument's clock or ring
// pointers: it must keep logging across a guest reset).
/* verilator lint_off PROCASSINIT */
module pc9821_gdc_log #(
    parameter integer LOG_CLK_HZ = 50_000_000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        io_wr,
    input  wire [15:0] io_addr,
    input  wire [7:0]  io_din,
    input  wire [9:0]  vline,
    input  wire        tram_we,
    input  wire [13:0] tram_addr,
    input  wire [7:0]  tram_din,
    output wire [7:0]  log_byte,
    output wire        log_we,
    input  wire        log_accept
);
  localparam integer MS_DIV = LOG_CLK_HZ / 1000;
  reg [31:0] ms_div = 32'd0;
  reg [15:0] ms = 16'd0;
  always @(posedge clk) begin
    if (ms_div == MS_DIV - 1) begin ms_div <= 32'd0; ms <= ms + 16'd1; end
    else ms_div <= ms_div + 32'd1;
  end

  // The port decode: n as in the record table, 4'hF = not logged.
  reg [3:0] pn;
  always @* begin
    case (io_addr)
      16'h0060: pn = 4'd0;  16'h0062: pn = 4'd1;  16'h00A0: pn = 4'd2;  16'h00A2: pn = 4'd3;
      16'h0068: pn = 4'd4;  16'h006A: pn = 4'd5;  16'h00A4: pn = 4'd6;  16'h00A6: pn = 4'd7;
      16'h09A8: pn = 4'd8;
      default:  pn = 4'hF;
    endcase
  end

  // The display commands, and the subset whose parameter bytes are display state.
  function automatic disp_cmd(input [7:0] c);
    disp_cmd = (c == 8'h00) || (c == 8'h05) || (c == 8'h06) || (c == 8'h0C) || (c == 8'h0D) ||
               (c == 8'h0E) || (c == 8'h0F) || (c == 8'h46) || (c == 8'h47) || (c == 8'h4B) ||
               (c == 8'h6B) || (c == 8'h6E) || (c == 8'h6F) || (c[7:4] == 4'h7);
  endfunction
  function automatic disp_par(input [7:0] c);
    disp_par = (c == 8'h06) || (c == 8'h0E) || (c == 8'h0F) || (c == 8'h46) || (c == 8'h47) ||
               (c == 8'h4B) || (c[7:4] == 4'h7);
  endfunction
  reg [7:0] cmd1 = 8'h00, cmd2 = 8'h00;   // each GDC's current command
  reg [7:0] last [0:4];                   // the last value logged per register port (n = 4..8)
  reg [4:0] seen = 5'd0;                  // ... and whether one has been logged since reset
  wire [2:0] ri = {pn[3], pn[1:0]};   // n 4..8 -> 0..4
  wire is_reg = (pn >= 4'd4) && (pn <= 4'd8);
  // The port decode is the address qualifier on the shared I/O strobe (tools/check_shared_strobes.py).
  wire port_sel = (pn != 4'hF);
  wire want = io_wr && port_sel && (
      (pn == 4'd1 || pn == 4'd3) ? disp_cmd(io_din) :
      (pn == 4'd0) ? disp_par(cmd1) :
      (pn == 4'd2) ? disp_par(cmd2) :
      is_reg ? (!seen[ri] || last[ri] != io_din) : 1'b0);

  reg        p_alive = 1'b1;   // power-up
  reg        rst_d = 1'b0;
  reg  [7:0] lost = 8'd0;
  reg        busy = 1'b0;
  reg  [3:0] r_i = 4'd0;
  reg  [7:0] r_type = 8'd0, r_val = 8'd0;
  reg [15:0] r_t = 16'd0;
  reg [15:0] r_v = 16'd0;     // bytes 4/5: the raster line, or the previous run's last cell
  reg [11:0] r_w = 12'd0;     // bytes 6/7 of an attribute record: the run's first cell
  // The attribute run tracker: every attribute write moves it; a break is logged.
  reg [11:0] t_last = 12'hFFF;
  reg  [7:0] t_lastv = 8'h00;
  wire       t_attr = tram_we && tram_addr[13] && !tram_addr[0];
  wire [11:0] t_cell = tram_addr[12:1];
  wire       want_t = t_attr && ((tram_din != t_lastv) || (t_cell != t_last + 12'd1));
  wire       room;
  reg        push;
  wire       r_long = (r_type == 8'h19);
  wire [3:0] r_last = r_long ? 4'd8 : 4'd6;
  reg  [7:0] r_byte;
  always @* begin
    case (r_i)
      4'd0: r_byte = 8'hA5;
      4'd1: r_byte = r_type;
      4'd2: r_byte = r_t[15:8];
      4'd3: r_byte = r_t[7:0];
      4'd4: r_byte = r_v[15:8];
      4'd5: r_byte = r_v[7:0];
      4'd6: r_byte = r_long ? {4'd0, r_w[11:8]} : r_val;
      4'd7: r_byte = r_w[7:0];
      default: r_byte = r_val;
    endcase
  end
  always @(posedge clk) begin
    rst_d <= rst_n;
    if (!rst_n) begin
      cmd1 <= 8'h00; cmd2 <= 8'h00; seen <= 5'd0;
    end else if (io_wr && port_sel) begin
      if (pn == 4'd1) cmd1 <= io_din;
      if (pn == 4'd3) cmd2 <= io_din;
    end
    if (rst_n && !rst_d) p_alive <= 1'b1;
    if (t_attr) begin t_last <= t_cell; t_lastv <= tram_din; end
    // one record at a time; a port write takes the stage over the ALIVE/LOST records
    if (!busy) begin
      if (want && rst_n && room) begin
        busy <= 1'b1; r_i <= 4'd0; r_t <= ms; r_v <= {6'd0, vline}; r_type <= {4'h1, pn}; r_val <= io_din;
        if (is_reg) begin last[ri] <= io_din; seen[ri] <= 1'b1; end
      end else if (want && rst_n) begin
        if (lost != 8'hFF) lost <= lost + 8'd1;
      end else if (want_t && rst_n && room) begin
        busy <= 1'b1; r_i <= 4'd0; r_t <= ms; r_v <= {4'd0, t_last}; r_w <= t_cell;
        r_type <= 8'h19; r_val <= tram_din;
      end else if (want_t && rst_n) begin
        if (lost != 8'hFF) lost <= lost + 8'd1;
      end else if (p_alive && rst_n && room) begin
        busy <= 1'b1; r_i <= 4'd0; r_t <= ms; r_v <= {6'd0, vline}; r_type <= 8'h1F; r_val <= 8'h5A; p_alive <= 1'b0;
      end else if (lost != 8'd0 && room) begin
        busy <= 1'b1; r_i <= 4'd0; r_t <= ms; r_v <= {6'd0, vline}; r_type <= 8'h1E; r_val <= lost; lost <= 8'd0;
      end
    end else begin
      if ((want || want_t) && lost != 8'hFF) lost <= lost + 8'd1;
      r_i <= r_i + 4'd1;
      if (r_i == r_last) busy <= 1'b0;
    end
  end
  // the ring and its drain to the UART FIFO
  always @* push = busy;
  pc9821_dbg_ring #(.AW(11), .MAX_REC(16)) u_ring (
      .clk(clk), .push(push), .din(r_byte), .room(room),
      .log_byte(log_byte), .log_we(log_we), .log_accept(log_accept));
endmodule
/* verilator lint_on PROCASSINIT */
`default_nettype wire
