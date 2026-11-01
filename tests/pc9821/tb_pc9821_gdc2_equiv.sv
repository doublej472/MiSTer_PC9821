`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The graphics GDC's area rewrite (the draw engine's unit count held as leng-1 in 16 bits, the cursor advance summed in one adder) is cycle-for-cycle identical to the pre-rewrite module (pc9821_gdc2_ref.sv, the module as of 3b134fe4, with the two changes the figure engine makes to what the WRITE slice shows mirrored into it: CSRW's third byte loads the mask with its dAD one-hot, and 0xA0 status bit 3 reads DRAWING): over several hundred thousand clk_sys cycles of random well-formed and cut-short command streams on the 0xA0/0xA2 ports (SCROLL/TEXTW, SYNC, CSRW, CSRFORM, VECTW in all eight directions, MASK, every WRITE width and ROP, START/STOP, CSRR/LPEN read-back, and random command bytes except the figure engine's ZOOM/GCHRD/FIGD, which the pre-rewrite module never had) against a randomly-stalling GVRAM visit port, with a raster that wraps and snapshots, and one 65,536-unit draw, on streams that leave each WRITE job to finish before their next byte (the shipped module queues a byte written during a walk in its command FIFO, which the pre-rewrite module did not have; tb_pc9821_gdc2_write CHECK 8 pins that order), every output (io_dout, the scanout address and enables, the draw engine's visit port) matches on every cycle.

// ==== DUT ====
// pc9821_gdc2 vs pc9821_gdc2_ref, same inputs. The reference is the pre-change text, not a model of
// the hardware: this bench proves the rewrite did not change behaviour; the engine's behaviour
// itself is pinned by tb_pc9821_gdc2_write and tb_pc9821_gdc2_scroll.

module tb_pc9821_gdc2_equiv;
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg        io_wr = 0, io_rd = 0;
  reg  [7:0] io_addr = 8'hA0, io_din = 0;
  reg        pixel_ce = 1;
  reg        frame_end = 0, cfg_snap = 0, cfg_pending = 0;
  reg  [9:0] vline = 0;
  reg  [9:0] vtotal = 10'd440;
  reg  [5:0] m_vbp = 6'd25;
  reg        display_page = 0, pegc_256 = 0, stat_blank = 0, stat_vsync = 0, gdc_5m = 0;
  reg        egc_mem_gate = 0, grcg_cg_gate = 0, access_page = 0;
  reg        mem_ready = 0, mem_resp = 0;
  reg [31:0] mem_rdata = 0;

  `define OUTS(p) \
    wire [7:0] p``_io_dout; wire [15:0] p``_line; wire p``_walk_page, p``_disp, p``_win_off, p``_grph_on; \
    wire p``_mv, p``_mw, p``_mre, p``_mrg, p``_mp; wire [1:0] p``_mpl; wire [14:0] p``_mo; \
    wire [31:0] p``_md; wire [3:0] p``_mb;
  `OUTS(d)
  `OUTS(r)

  pc9821_gdc2 dut (
    .clk_sys(clk), .rst_n_sys(rst_n), .pixel_ce(pixel_ce),
    .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din), .io_dout(d_io_dout),
    .frame_end(frame_end), .cfg_snap(cfg_snap), .cfg_pending(cfg_pending), .vline(vline),
    .vtotal(vtotal), .m_vbp(m_vbp), .display_page(display_page), .pegc_256(pegc_256), .gdc_5m(gdc_5m),
    .stat_blank(stat_blank), .stat_vsync(stat_vsync),
    .gfx_line_addr(d_line), .gfx_walk_page(d_walk_page), .gfx_disp(d_disp),
    .gfx_win_off(d_win_off), .gfx_grph_on(d_grph_on),
    .egc_mem_gate(egc_mem_gate), .grcg_cg_gate(grcg_cg_gate), .access_page(access_page),
    .mem_valid(d_mv), .mem_ready(mem_ready), .mem_write(d_mw), .mem_route_egc(d_mre),
    .mem_route_grcg(d_mrg), .mem_page(d_mp), .mem_plane(d_mpl), .mem_offset(d_mo),
    .mem_din(d_md), .mem_be(d_mb), .mem_resp(mem_resp), .mem_rdata(mem_rdata));
  pc9821_gdc2_ref ref0 (
    .clk_sys(clk), .rst_n_sys(rst_n), .pixel_ce(pixel_ce),
    .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din), .io_dout(r_io_dout),
    .frame_end(frame_end), .cfg_snap(cfg_snap), .cfg_pending(cfg_pending), .vline(vline),
    .vtotal(vtotal), .m_vbp(m_vbp), .display_page(display_page), .pegc_256(pegc_256), .gdc_5m(gdc_5m),
    .stat_blank(stat_blank), .stat_vsync(stat_vsync),
    .gfx_line_addr(r_line), .gfx_walk_page(r_walk_page), .gfx_disp(r_disp),
    .gfx_win_off(r_win_off), .gfx_grph_on(r_grph_on),
    .egc_mem_gate(egc_mem_gate), .grcg_cg_gate(grcg_cg_gate), .access_page(access_page),
    .mem_valid(r_mv), .mem_ready(mem_ready), .mem_write(r_mw), .mem_route_egc(r_mre),
    .mem_route_grcg(r_mrg), .mem_page(r_mp), .mem_plane(r_mpl), .mem_offset(r_mo),
    .mem_din(r_md), .mem_be(r_mb), .mem_resp(mem_resp), .mem_rdata(mem_rdata));

  integer errors = 0, cycles = 0, seed = 7, long_mode = 0, visits = 0;
  reg [31:0] rnd;

  // ---- the command queue: a byte list (cmd flag, value) drained one write per few cycles ----
  reg        q_cmd [0:63];
  reg  [7:0] q_val [0:63];
  integer    q_n = 0, q_i = 0;
  task automatic push(input c, input [7:0] v);
    begin q_cmd[q_n] = c; q_val[q_n] = v; q_n = q_n + 1; end
  endtask
  function automatic [7:0] r8(input integer dummy);
    reg [31:0] x;
    begin x = $random(seed); r8 = x[7:0]; end
  endfunction
  task automatic gen_cmd;
    reg [31:0] x;
    integer k, n;
    begin
      q_n = 0; q_i = 0;
      x = $random(seed);
      case (x[3:0])
        4'd0: begin push(1, 8'h70 + {4'd0, x[7:4] & 4'h7}); for (k = 0; k < 16 - (x[7:4] & 7); k = k + 1) push(0, r8(0)); end
        4'd1: begin push(1, 8'h0F); for (k = 0; k < 8; k = k + 1) push(0, r8(0)); end
        4'd2: begin push(1, 8'h49); push(0, r8(0)); push(0, {2'b00, r8(0) & 8'h3F}); push(0, r8(0)); end
        4'd3: begin push(1, 8'h4B); push(0, r8(0)); push(0, r8(0)); push(0, r8(0)); end
        4'd4, 4'd5: begin   // VECTW: direction in byte 0, a short length unless a long run was asked for
          push(1, 8'h4C); push(0, {5'd0, x[10:8]});
          if (long_mode) begin push(0, 8'hFF); push(0, 8'hFF); end
          else begin push(0, r8(0) & 8'h1F); push(0, (x[12] ? 8'h01 : 8'h00)); end
          for (k = 0; k < 8; k = k + 1) push(0, r8(0));
        end
        4'd6: begin push(1, 8'h4A); push(0, r8(0)); push(0, r8(0)); end
        4'd7, 4'd8, 4'd9: begin   // WRITE: random ROP/width, then its data bytes
          push(1, 8'h20 | (r8(0) & 8'h1B)); push(0, r8(0)); push(0, r8(0));
        end
        4'd10: push(1, x[8] ? 8'h0D : 8'h0C);
        4'd11: push(1, 8'hE0);
        4'd12: push(1, 8'hC0);
        4'd13: begin push(1, 8'h6B); end
        4'd14: begin   // anything at all - but the figure engine's commands (ZOOM 0x46, GCHRD
          // 0x68, FIGD 0x6C), which the pre-rewrite module never had, become their no-op neighbours
          k = r8(0);
          if ((k == 8'h46) || (k == 8'h68) || (k == 8'h6C)) k = k ^ 1;
          push(1, k[7:0]); push(0, r8(0));
        end
        default: begin push(0, r8(0)); end
      endcase
    end
  endtask

  // ---- the GVRAM visit port: a random accept, and a read's datum on a LATER cycle than its
  // ready (the responder contract), sampled at the clock edge the DUT samples on ----
  integer rd_age = 0;
  reg rd_pend = 0;
  reg [31:0] mrnd;
  always @(posedge clk) if (rst_n) begin
    mrnd = $random(seed);
    mem_ready <= d_mv && !mem_ready && (mrnd[2:0] > 3'd1);
    mem_resp <= rd_pend && (mrnd[4] || rd_age > 2);
    if (rd_pend && (mrnd[4] || rd_age > 2)) rd_pend = 0;
    else if (rd_pend) rd_age = rd_age + 1;
    if (d_mv && mem_ready) begin
      visits = visits + 1;
      if (!d_mw) begin rd_pend = 1; rd_age = 0; mem_rdata <= $random(seed); end
    end
  end

  // ---- the stimulus ----
  integer wait_n = 0;
  integer h = 0;
  always @(negedge clk) if (rst_n) begin
    cycles = cycles + 1;
    rnd = $random(seed);
    // the raster: a pixel every cycle (mostly), 40 dots per line
    pixel_ce <= (rnd[7:4] != 0);
    if (pixel_ce) begin
      h = h + 1;
      frame_end <= 0; cfg_snap <= 0;
      if (h == 40) begin
        h = 0;
        vline <= (vline == vtotal - 1) ? 10'd0 : vline + 10'd1;
        if (vline == vtotal - 2) begin
          frame_end <= 1; cfg_snap <= cfg_pending;
        end
      end
    end
    if (cycles % 20000 == 0) begin
      cfg_pending <= rnd[0]; pegc_256 <= rnd[1]; display_page <= rnd[2]; gdc_5m <= rnd[3];
      m_vbp <= 6'd20 + rnd[8:5]; vtotal <= 10'd400 + {1'b0, rnd[17:9]} % 10'd100;
      stat_blank <= rnd[18]; stat_vsync <= rnd[19];
    end
    egc_mem_gate <= (rnd[13:11] == 0);
    grcg_cg_gate <= (rnd[16:14] == 0);
    access_page <= rnd[17];
    // the command port
    io_wr <= 0; io_rd <= 0;
    // No byte while the shipped module's WRITE engine holds a job: the shipped module queues
    // such bytes behind the draw in its command FIFO (the uPD7220's in-order execution), the
    // pre-rewrite module parsed them at once, so the two are compared on streams that leave
    // each WRITE to finish first; the in-order queueing itself is tb_pc9821_gdc2_write's CHECK 8.
    if (wait_n > 0) wait_n = wait_n - 1;
    else if (q_i < q_n) begin
      if ((dut.pend_valid === 1'b0) && (dut.d_state === 3'd0)) begin
        io_wr <= 1; io_addr <= q_cmd[q_i] ? 8'hA2 : 8'hA0; io_din <= q_val[q_i];
        q_i = q_i + 1; wait_n = rnd[22:20] % 4;
      end
    end else begin
      if (rnd[25:23] == 0) begin io_rd <= 1; io_addr <= rnd[26] ? 8'hA2 : 8'hA0; end
      else if (rnd[25:23] < 3) begin io_addr <= rnd[26] ? 8'hA2 : 8'hA0; end
      if (rnd[31:27] == 0 || (long_mode && !d_mv && rnd[31:27] < 2)) gen_cmd;
    end
  end

  // ==== CHECKS ====
  always @(posedge clk) if (rst_n) begin
    if (d_io_dout !== r_io_dout || d_line !== r_line || d_walk_page !== r_walk_page ||
        d_disp !== r_disp || d_win_off !== r_win_off || d_grph_on !== r_grph_on ||
        d_mv !== r_mv || d_mw !== r_mw || d_mre !== r_mre || d_mrg !== r_mrg ||
        d_mp !== r_mp || d_mpl !== r_mpl || d_mo !== r_mo || d_md !== r_md || d_mb !== r_mb) begin
      errors = errors + 1;
      if (errors < 10)
        $display("FAIL cycle %0d: io %02h/%02h line %04h/%04h mv %b/%b mo %04h/%04h md %08h/%08h",
                 cycles, d_io_dout, r_io_dout, d_line, r_line, d_mv, r_mv, d_mo, r_mo, d_md, r_md);
    end
  end

  // ==== VERDICT ====
  integer pass;
  initial begin
    repeat (4) @(posedge clk);
    for (pass = 0; pass < 3; pass = pass + 1) begin
      seed = 31 + pass;
      rst_n = 0; repeat (4) @(posedge clk); rst_n = 1;
      repeat (150000) @(posedge clk);
    end
    // one maximum-length draw (VECTW length 0xFFFF = 65,536 units): the 16-bit count's boundary
    long_mode = 1;
    rst_n = 0; repeat (4) @(posedge clk); rst_n = 1;
    q_n = 0; q_i = 0;
    push(1, 8'h4C); push(0, 8'h02); push(0, 8'hFF); push(0, 8'hFF);
    for (pass = 0; pass < 8; pass = pass + 1) push(0, 8'h00);
    push(1, 8'h22); push(0, 8'hA5); push(0, 8'h5A);
    repeat (2000000) @(posedge clk);
    if (visits < 1000) $fatal(1, "TB_PC9821_GDC2_EQUIV: only %0d visits - the stimulus did not exercise the draw engine", visits);
    if (errors != 0) $fatal(1, "TB_PC9821_GDC2_EQUIV: %0d mismatches over %0d cycles", errors, cycles);
    $display("TB_PC9821_GDC2_EQUIV: PASS");
    $display("NOTE gdc2_equiv: %0d cycles, %0d visits, identical", cycles, visits);
    $finish;
  end
endmodule
