`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_GDC_EGC_GATE: the EGC memory-dispatch gate `mode2_egc && GRCG 0x7C bit 7` is REGISTERED FROM BOTH SOURCES' NEXT STATE (pc9821_egc_mem_gate, opt-video VID-1) and is therefore bit-identical, every cycle after reset, to the combinational gate it replaces: the registered gate equals the AND of the two live source registers in EVERY cycle, and a GVRAM request presented in the first cycle after either source moves (the cycle a lagged register would serve stale) is dispatched by the NEW value - the EGC owns the store when the gate is on and does not when it is off. FAIL-FIRST: replacing the next-state form with the plain lagged `gate_q <= egc_gate & grcg_expand` makes the registered gate one cycle behind on every source move, so the same-cycle request check and the transparency check both FAIL.

// WHY THIS BENCH EXISTS. The register is a TRUE PIPELINE RELOCATE only if gate(t) ==
// egc_gate(t) && grcg_expand(t) for every t (the pre-change combinational value). A plain
// register lags one cycle, and a GVRAM store/draw whose dispatch is decided in the cycle the mode
// latch moves would then take the OLD owner - a guest-visible mode-latch timing. The
// transparency check below is that claim; the directed sequence presents the request in the exact
// cycle after each edge and requires the new dispatch. The sources are modelled here at their own
// register semantics; the next-state correctness of the REAL pc9821_crtc/pc9821_grcg exports is
// proven by tools/check_gdc_egc_gate_inv.py (induction over the real modules).
`default_nettype none

module tb_pc9821_gdc_egc_gate;
  localparam integer CYCLE_NS = 20;

  reg clk = 1'b0;
  always #(CYCLE_NS/2) clk = ~clk;
  reg reset = 1'b1;

  integer errors = 0;
  task automatic fail(input [8*160-1:0] what);
    begin
      $display("FAIL %0s", what);
      errors = errors + 1;
    end
  endtask

  // ==== the two source registers, at their own RTL semantics ====
  // mode2_egc: FF2 num 2, gated by mode2_wren (FF2 num 3). mode2_wren and mode2_egc are the
  // pc9821_crtc registers; their next state is `wr ? bit : cur`.
  reg m2_wren = 1'b0, m2_egc = 1'b0, m7 = 1'b0;
  reg m2_wren_wr = 1'b0, m2_wren_bit = 1'b0;   // num 3 write
  reg m2_wr = 1'b0, m2_bit = 1'b0;             // num 2 write
  reg m7_wr = 1'b0, m7_bit = 1'b0;             // 0x7C bit 7 write
  wire m2_nx = m2_wr ? m2_bit : m2_egc;
  wire m7_nx = m7_wr ? m7_bit : m7;
  always @(posedge clk) begin
    if (reset) begin
      m2_wren <= 1'b0; m2_egc <= 1'b0; m7 <= 1'b0;
    end else begin
      if (m2_wren_wr) m2_wren <= m2_wren_bit;
      if (m2_wr)      m2_egc  <= m2_nx;   // the register's own next-state expression
      if (m7_wr)      m7      <= m7_nx;
    end
  end

  // ==== DUT ====
  wire gate;
  pc9821_egc_mem_gate dut (
      .clk(clk), .reset(reset),
      .egc_gate(m2_egc), .egc_gate_nx(m2_nx),
      .grcg_expand(m7), .grcg_expand_nx(m7_nx),
      .gate(gate));

  // ==== the CONSUMER: the real GVRAM arbiter, its EGC owner decode driven by the gate ====
  reg        access_page = 1'b0;
  reg  [1:0] win_plane = 2'd0;
  reg [14:0] win_offset = 15'd0;
  reg [31:0] cpu_din = 32'd0;
  reg  [3:0] cpu_be = 4'hF;
  reg        cpu_line_read = 1'b0;
  reg        cpu_valid = 1'b0, cpu_write = 1'b0;
  wire [31:0]  cpu_dout;
  wire [31:0] cpu_line_word;
  wire         cpu_ready, cpu_resp_valid, cpu_line_word_valid;
  reg        grcg_we = 1'b0;
  reg  [7:0] grcg_addr = 8'd0, grcg_din = 8'd0;
  wire       grcg_expand;
  reg [15:0] egc_access = 16'hFFF0, egc_fgbg = 16'h00FF, egc_ope = 16'h00F0,
             egc_fg = 16'd0, egc_mask = 16'hFFFF, egc_bg = 16'd0,
             egc_sft = 16'd0, egc_leng = 16'h000F;
  reg        egc_shift_we = 1'b0;
  reg        gdc_mem_valid = 1'b0, gdc_mem_write = 1'b0;
  reg        gdc_mem_route_egc = 1'b0, gdc_mem_route_grcg = 1'b0, gdc_mem_page = 1'b0;
  reg  [1:0] gdc_mem_plane = 2'd0;
  reg [14:0] gdc_mem_offset = 15'd0;
  reg [31:0] gdc_mem_din = 32'd0;
  reg  [3:0] gdc_mem_be = 4'hF;
  wire       gdc_mem_ready, gdc_mem_resp;
  wire [31:0] gdc_mem_rdata;
  reg        scan_enable = 1'b0, scan_line_tick = 1'b0, scan_page = 1'b0;
  reg [14:0] scan_line_base = 15'd0;
  reg  [6:0] line_rd_addr = 7'd0;
  reg        line_rd_sel = 1'b0;
  wire [31:0] line_data;
  wire        line_sel, line_ready;

  pc9821_gvram_dut cons (
      .clk(clk), .reset(reset),
      .access_page(access_page),
      .win_plane(win_plane), .win_offset(win_offset),
      .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_line_read(cpu_line_read),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_dout(cpu_dout), .cpu_line_word(cpu_line_word),
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_word_valid(cpu_line_word_valid),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din),
      .grcg_expand(grcg_expand),
      .egc_gate(gate), .egc_access(egc_access), .egc_fgbg(egc_fgbg),
      .egc_ope(egc_ope), .egc_fg(egc_fg), .egc_mask(egc_mask),
      .egc_bg(egc_bg), .egc_sft(egc_sft), .egc_leng(egc_leng),
      .egc_shift_we(egc_shift_we),
      .gdc_mem_valid(gdc_mem_valid), .gdc_mem_ready(gdc_mem_ready),
      .gdc_mem_write(gdc_mem_write), .gdc_mem_route_egc(gdc_mem_route_egc),
      .gdc_mem_route_grcg(gdc_mem_route_grcg), .gdc_mem_page(gdc_mem_page),
      .gdc_mem_plane(gdc_mem_plane), .gdc_mem_offset(gdc_mem_offset),
      .gdc_mem_din(gdc_mem_din), .gdc_mem_be(gdc_mem_be),
      .gdc_mem_resp(gdc_mem_resp), .gdc_mem_rdata(gdc_mem_rdata),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .scan_line_base(scan_line_base),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready));

  // ==== CHECKS ====
  // ==== the transparency claim, EVERY cycle: the registered gate is the combinational gate ====
  // This is the pre-change behaviour (the reference for a zero-cycle relocate), not a value the
  // register itself produced. It fires one cycle after a source moves under the lagged mutant.
  integer trans_bad = 0;
  always @(posedge clk) begin
    if (!reset && (gate !== (m2_egc & m7))) begin
      if (trans_bad == 0) fail("transparency: gate != mode2_egc & grcg_mode7");
      trans_bad = trans_bad + 1;
    end
  end

  // Present a one-cycle GVRAM store and return the consumer's owner decode in the presenting
  // cycle (before any accept latches it). `expect_egc` 1: the EGC must own it.
  task automatic probe_store(input bit expect_egc, input [8*120-1:0] what, input bit check_flag);
    begin
      @(negedge clk);
      win_plane = 2'd1; win_offset = 15'd64; cpu_din = 32'hA5A5_A5A5; cpu_be = 4'hF;
      cpu_line_read = 1'b0; cpu_write = 1'b1; cpu_valid = 1'b1;
      #1;
      if (check_flag) begin
        if (cons.u_arb.own_egc !== expect_egc) begin
          $display("FAIL %0s: own_egc=%0b gate=%0b want egc=%0b", what, cons.u_arb.own_egc, gate, expect_egc);
          errors = errors + 1;
        end
        // and it is the flip of the GRCG owner when the EGC gate is the only other owner
      end
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0;
      // drain the walk so the next probe starts from idle
      while ((cons.u_arb.gstate != 3'd0) || cons.u_arb.m_mode || (cons.u_arb.cs != 4'd0) ||
             (cons.u_grcg.gstate != 4'd0) || (cons.u_egc.state != 4'd0)) @(posedge clk);
      repeat (2) @(posedge clk);
    end
  endtask

  // One mode-write cycle through the CRTC's FF2 num 2 (with mode2_wren already set).
  task automatic wr_num2(input bit v);
    begin
      @(negedge clk); m2_wr = 1'b1; m2_bit = v;
      @(negedge clk); m2_wr = 1'b0;
    end
  endtask

  task automatic wr_num3(input bit v);
    begin
      @(negedge clk); m2_wren_wr = 1'b1; m2_wren_bit = v;
      @(negedge clk); m2_wren_wr = 1'b0;
    end
  endtask

  task automatic wr_7c_bit7(input bit v);
    begin
      @(negedge clk); m7_wr = 1'b1; m7_bit = v;
      @(negedge clk); m7_wr = 1'b0;
    end
  endtask

  // ==== VERDICT ====
  integer t;
  initial begin
    // reset
    repeat (6) @(posedge clk);
    @(negedge clk); reset = 1'b0;
    repeat (4) @(posedge clk);

    // Turn on the EGC register write enable (FF2 num 3) and the GRCG CG mode (0x7C bit 7).
    wr_num3(1'b1);
    wr_7c_bit7(1'b1);
    repeat (2) @(posedge clk);

    // ---- gate OFF (mode2_egc still 0): a store is NOT the EGC's ----
    probe_store(1'b0, "egc off: store not EGC-owned", 1'b1);

    // ---- 0 -> 1: enable the EGC (FF2 num 2), then present the request in the FIRST cycle the
    //      new value is valid. A lagged register still sees 0 here and mis-dispatches. ----
    wr_num2(1'b1);
    // the write's edge has passed at the second negedge above; both sources are now 1
    if (gate !== 1'b1) fail("enable: gate not 1 in the cycle after the FF2 num-2 write");
    probe_store(1'b1, "enable: store IS EGC-owned the cycle after the mode latch moves", 1'b1);

    // ---- 1 -> 0: disable the EGC, present the request in the first cycle the new value is
    //      valid. A lagged register still sees 1 here and mis-dispatches. ----
    wr_num2(1'b0);
    if (gate !== 1'b0) fail("disable: gate not 0 in the cycle after the FF2 num-2 write");
    probe_store(1'b0, "disable: store NOT EGC-owned the cycle after the mode latch moves", 1'b1);

    // ---- the other source (GRCG 0x7C bit 7) moves while mode2_egc is on ----
    wr_num2(1'b1);
    repeat (2) @(posedge clk);
    probe_store(1'b1, "egc on, grcg on: store IS EGC-owned", 1'b1);
    wr_7c_bit7(1'b0);
    if (gate !== 1'b0) fail("grcg off: gate not 0 the cycle after the 0x7C write");
    probe_store(1'b0, "grcg off: store NOT EGC-owned the cycle after the 0x7C write", 1'b1);
    wr_7c_bit7(1'b1);
    if (gate !== 1'b1) fail("grcg on: gate not 1 the cycle after the 0x7C write");
    probe_store(1'b1, "grcg on: store IS EGC-owned the cycle after the 0x7C write", 1'b1);

    // ---- a pseudo-random sweep: move either source on random cycles and check the gate is the
    //      combinational AND in every cycle (the transparency monitor above is the judge) ----
    for (t = 0; t < 200; t = t + 1) begin
      @(negedge clk);
      m2_wr = ($random % 3) == 0;  m2_bit = $random;
      m7_wr = ($random % 4) == 0;  m7_bit = $random;
      m2_wren_wr = 0;
      @(negedge clk); m2_wr = 0; m7_wr = 0;
    end
    repeat (4) @(posedge clk);

    if (trans_bad != 0) begin
      $display("FAIL transparency failed in %0d cycles", trans_bad);
      errors = errors + 1;
    end
    if (errors != 0) begin
      $display("TB_PC9821_GDC_EGC_GATE: FAIL (%0d)", errors);
      $fatal(1, "TB_PC9821_GDC_EGC_GATE failed");
    end
    $display("TB_PC9821_GDC_EGC_GATE: PASS");
    $finish;
  end

  // Simulated-time watchdog: a hang is a FAIL, not a timeout.
  initial begin
    #(2_000_000);
    $fatal(1, "TB_PC9821_GDC_EGC_GATE did not finish in 2 ms of simulated time");
  end
endmodule

`default_nettype wire
