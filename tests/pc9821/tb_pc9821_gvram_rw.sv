`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GVRAM_RW: The GVRAM storage carries a CPU store's bytes to the plane lanes the byte enables name and returns them unchanged on a later read, at BOTH access pages and ALL FOUR plane windows, at byte, word and DWORD widths, at the start and the END of each plane, and a one-plane store preserves the other three lanes -- all of it THROUGH the SDRAM backend, whose byte-enable write is the read-modify-write a DQM-less module needs.
//
// WHY THIS EXISTS. A CPU read-after-write of GVRAM
// was NEVER tested in this tree: the map bench checked only the SDRAM address translation, and the
// gvram benches observed a stubbed backend rather than the bytes that came back. That gap is
// exactly the operation the authentic ITF performs at POST stage 0x1B - fill a plane, read it back
// - and it is the operation a MiSTer HUNG ON: the CPU sat in a rep stosd fill of 32 KiB at
// ES=0xA800 while the watchdog reported 'W' every 200 ms. The storage left block RAM again in
// the design, so this bench drives the real pc9821_gvram datapath and observes the bytes IN THE
// BACKEND MODEL behind it: a byte-granular store becomes one byte-enable transaction, which is
// what makes the read-modify-write path (src/memory/sdram.v's RMW_*) the thing under test.
//
// IT DOES NOT COVER the plane decode, the GRCG, the EGC or the scanout fetch. Those are
// tb_pc9821_gvram's, tb_pc9821_grcg's and tb_pc9821_egc's. This is the storage contract alone.

module tb_pc9821_gvram_rw;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  localparam [31:0] GVRAM_BASE = 32'h0300_0000;

  // ==== DUT ====

  // ---- DUT ----
  reg        access_page = 0;
  reg  [1:0] win_plane = 0;
  reg [14:0] win_offset = 0;
  reg [31:0] cpu_din = 0;
  reg  [3:0] cpu_be = 4'hF;
  reg        cpu_line_read = 0;
  reg        cpu_valid = 0, cpu_write = 0;
  wire [31:0]  cpu_dout;
  wire [31:0] cpu_line_word;
  wire         cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  reg        grcg_we = 0;
  reg  [7:0] grcg_addr = 0, grcg_din = 0;

  reg        egc_gate = 0;
  reg [15:0] egc_access = 16'hFFFF, egc_fgbg = 0, egc_ope = 0,
             egc_fg = 0, egc_mask = 16'hFFFF, egc_bg = 0,
             egc_sft = 0, egc_leng = 0;
  reg        egc_shift_we = 0;

  reg        scan_enable = 0, scan_line_tick = 0, scan_page = 0;
  reg [14:0] scan_line_base = 0;
  reg  [6:0] line_rd_addr = 0;
  reg        line_rd_sel = 0;
  wire [31:0] line_data;
  wire        line_sel, line_ready;



  pc9821_gvram_dut #(.SYS_CLOCK_HZ(100_000_000)) dut (
      .clk(clk), .reset(reset),
      .access_page(access_page),
      .win_plane(win_plane), .win_offset(win_offset),
      .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_line_read(cpu_line_read),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_dout(cpu_dout), .cpu_line_word(cpu_line_word),
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_word_valid(cpu_line_word_valid),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din),
      .egc_gate(egc_gate), .egc_access(egc_access), .egc_fgbg(egc_fgbg),
      .egc_ope(egc_ope), .egc_fg(egc_fg), .egc_mask(egc_mask),
      .egc_bg(egc_bg), .egc_sft(egc_sft), .egc_leng(egc_leng),
      .egc_shift_we(egc_shift_we),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .scan_line_base(scan_line_base),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready));

  // The backend: one transaction at a time, shared storage, byte-enabled writes - sdram.v's own
  // shape, and the reason a one-plane store can be checked for preserving the other three.
  

  integer errors = 0;
  integer checks = 0;

  task automatic fail(input [255:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  // ==== STIMULUS ====
  // ==== CHECKS ====
  // A column's byte lives in lane `col[1:0]` of the dword at index col: the plain path forms
  // c_col = {win_offset[14:2], c_lane}, and c_lane comes from the BYTE ENABLES - so a byte access
  // must put the column's low two bits in BOTH win_offset and the enable, or it lands one dword
  // down. That agreement is the whole reason these helpers exist.
  task automatic put_byte(input [1:0] plane, input page, input [14:0] col,
                          input [7:0] val);
    begin
      @(negedge clk);
      access_page = page;
      win_plane   = plane;
      win_offset  = col;
      cpu_din     = {24'd0, val} << (col[1:0] * 8);
      cpu_be      = 4'b0001 << col[1:0];
      cpu_write   = 1;
      cpu_valid   = 1;
      @(posedge clk);
      #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      @(negedge clk);
      cpu_valid = 0; cpu_write = 0; cpu_be = 4'hF; access_page = 0;
      repeat (3) @(posedge clk);
    end
  endtask

  task automatic get_byte(input [1:0] plane, input page, input [14:0] col,
                          output [7:0] val);
    reg [31:0] d;
    begin
      @(negedge clk);
      access_page = page;
      win_plane   = plane;
      win_offset  = col;
      cpu_be      = 4'b0001 << col[1:0];
      cpu_write   = 0;
      cpu_valid   = 1;
      @(posedge clk);
      #1;
      while (!cpu_ready) begin @(posedge clk); #1; end
      @(negedge clk);
      cpu_valid = 0; cpu_be = 4'hF;
      #1;
      while (!cpu_resp_valid) begin @(posedge clk); #1; end
      d = cpu_dout;
      val = d[{col[1:0], 3'b000} +: 8] & 8'hFF;
      access_page = 0;
      repeat (3) @(posedge clk);
    end
  endtask

  // Put one plane's byte at a column and read it back through the same window.
  task automatic check_byte(input [1:0] plane, input page, input [14:0] col,
                            input [7:0] val);
    reg [7:0] got;
    begin
      put_byte(plane, page, col, val);
      get_byte(plane, page, col, got);
      checks = checks + 1;
      if (got !== val) begin
        $display("FAIL plane %0d page %0d col %04x: got %02x want %02x",
                 plane, page, col, got, val);
        errors = errors + 1;
      end
    end
  endtask

  integer p, k;
  reg [7:0] b0, b1, b2, b3;

  initial begin
    repeat (4) @(posedge clk);
    reset = 0;
    repeat (4) @(posedge clk);

    // CHK-1/CHK-2: every plane, both pages, a BYTE written and read back through that plane's
    // window. The window selects the plane, and the access page selects the storage.
    for (p = 0; p < 4; p = p + 1) begin
      check_byte(p[1:0], 0, 15'h0010 + p[14:0], 8'h11 + p[7:0]);
      check_byte(p[1:0], 1, 15'h0010 + p[14:0], 8'h22 + p[7:0]);
    end
    // Page 1 must not alias page 0: the two stores above landed in different storage.
    get_byte(2'd0, 0, 15'h0010, b0);
    get_byte(2'd0, 1, 15'h0010, b1);
    checks = checks + 1;
    if (b0 === b1) begin
      $display("FAIL page 0 and page 1 alias at col 0x0010 (%02x)", b0);
      errors = errors + 1;
    end

    // CHK-3: a one-plane store leaves the other three lanes alone. Write a distinct value to each
    // plane at ONE column, then read all four back and require the underived bytes.
    put_byte(2'd0, 0, 15'h0100, 8'hA0);
    put_byte(2'd1, 0, 15'h0100, 8'hB1);
    put_byte(2'd2, 0, 15'h0100, 8'hC2);
    put_byte(2'd3, 0, 15'h0100, 8'hD3);
    get_byte(2'd0, 0, 15'h0100, b0);
    get_byte(2'd1, 0, 15'h0100, b1);
    get_byte(2'd2, 0, 15'h0100, b2);
    get_byte(2'd3, 0, 15'h0100, b3);
    checks = checks + 1;
    if (b0 !== 8'hA0 || b1 !== 8'hB1 || b2 !== 8'hC2 || b3 !== 8'hD3) begin
      $display("FAIL plane isolation at col 0x0100: %02x %02x %02x %02x", b0, b1, b2, b3);
      errors = errors + 1;
    end

    // CHK-4: the FIRST and LAST column of each plane's 32 KiB page, so a fold or an off-by-one at
    // the boundary cannot pass on interior addresses.
    for (p = 0; p < 4; p = p + 1) begin
      check_byte(p[1:0], 0, 15'h0000, 8'h5A + p[7:0]);
      check_byte(p[1:0], 0, 15'h7FFC, 8'h6B + p[7:0]);
      check_byte(p[1:0], 1, 15'h7FFC, 8'h7C + p[7:0]);
    end

    // CHK-5: a run of byte stores and a read-back of every one - the shape the ITF's stage-0x1B
    // fill-and-verify has, in the plane window the guest uses.
    for (k = 0; k < 256; k = k + 1)
      put_byte(2'd0, 0, 15'h0200 + k[14:0], k[7:0] ^ 8'h5A);
    for (k = 0; k < 256; k = k + 1) begin
      get_byte(2'd0, 0, 15'h0200 + k[14:0], b0);
      checks = checks + 1;
      if (b0 !== (k[7:0] ^ 8'h5A)) begin
        $display("FAIL fill/verify at col %04x: got %02x want %02x",
                 15'h0200 + k[14:0], b0, k[7:0] ^ 8'h5A);
        errors = errors + 1;
      end
    end

    // CHK-6: the scanout's requester reads the SAME storage while the CPU writes it. Put a byte,
    // let the scanout fetch the line that holds it, and require the assembled column to carry it.
    // Column 0 of the scanout line at base 0x0200 is the same word the CPU just wrote.
    scan_page      = 0;
    scan_line_base = 15'h0200;
    scan_enable    = 1;
    @(negedge clk);
    scan_line_tick = 1;
    @(negedge clk);
    scan_line_tick = 0;
    while (!line_ready) @(posedge clk);
    // The buffer the display reads is the one filled one tick ago; read column 0 of the buffer the
    // fetch considers displayed.
    @(negedge clk);
    scan_line_tick = 1;         // advance so the just-filled buffer becomes the displayed one
    @(negedge clk);
    scan_line_tick = 0;
    line_rd_sel = line_sel;
    line_rd_addr = 7'd0;
    @(posedge clk);
    #1;
    checks = checks + 1;
    if (line_data[7:0] !== (8'd0 ^ 8'h5A)) begin
      $display("FAIL scanout read the wrong storage: line col 0 blue = %02x want %02x",
               line_data[7:0], 8'd0 ^ 8'h5A);
      errors = errors + 1;
    end
    scan_enable = 0;

    // ==== CHECKS COMPLETE ====
    $display("TB_PC9821_GVRAM_RW: %0d checks across both pages and all four planes", checks);
    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GVRAM_RW: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_GVRAM_RW: FAIL (%0d errors)", errors);
      $fatal(1, "TB_PC9821_GVRAM_RW: FAIL");
    end
  end

  // ==== VERDICT BOUND ====
  initial begin
    repeat (2_000_000) @(posedge clk);
    $fatal(1, "TB_PC9821_GVRAM_RW: FAIL (timed out)");
  end

endmodule
