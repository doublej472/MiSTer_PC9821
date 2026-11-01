`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The graphics GDC's figure engine against a reference model transcribed into this bench (MAME upd7220.cpp's draw_line/draw_rectangle/draw_char/next_pixel - the step rules the Xe10 capture confirms row for row in tb_pc9821_gdc2_figure_xe10 - NP2kai's gdcsub_vectp single dot and gdcpset pattern rotation, and for the arc NP2kai gdcsub_vectc's circle evaluated exactly, s = round(r - sqrt(r^2 - i^2)) per step with r = D + 1, the datasheet's D = r - 1): arcs in all eight octants at radii 1..100 with and without a DM start and a rotating pattern; random lines in all eight octants (datasheet D/D1/D2), rectangles in all eight directions, characters with random PRAM rows, widths, zoom 1..4 and the slant, and single dots, under all four ROPs on random old GVRAM, compared word for word over all four planes of page 0 with the cursor and mask; a figure walking past the end of a plane carries into the next plane's words (and from 0xFFFF to 0x0000); the GRCG routes paint each dot as NP2kai's withtdw (the tile word to every plane) and withrmw (the tile bit at the dot) do; FIGD clears the FIGS block back to NP2kai's gdc_vectreset defaults, so a WRITE after it paints one unit; GCHRD without GC draws its FIGS figure with RA15 doubled as the pattern (NP2kai textdraw); CSRW's dAD reloads the mask after a MASK (the Xe10's MASK_THEN_CURS rows). The 16-entry command FIFO keeps order: a second figure's program written while the first draws (status bit 2 FIFO-empty clear, bit 1 FULL at 16 queued bytes, bit 3 DRAWING set) lands after it exactly as the model applies the two in turn. Every figure step takes 14 dot clocks, measured in pixel_ce enables at two different pixel_ce/clk_sys ratios with the same count, which is faster than both the Xe10's 2.5 MHz rate (GDCTIME: 3444 milli-ticks of the 2.4576 MHz PIT per dot, 29.5 dot clocks) and NP2kai's calc_gdcslavewait charge (0.72 us, 15.2 dot clocks).

module tb_pc9821_gdc2_figure;
  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;

  reg rst_n_sys = 0;
  reg io_wr = 0, io_rd = 0;
  reg [7:0] io_addr = 0, io_din = 0;
  wire [7:0] io_dout;
  wire [15:0] gfx_line_addr;
  wire gfx_disp;

  // pixel_ce: one enable every `pce_div` clk_sys (1 = every cycle).
  integer pce_div = 1, pce_cnt = 0;
  reg pixel_ce = 1'b1;
  always @(posedge clk_sys) begin
    pce_cnt <= (pce_cnt + 1 >= pce_div) ? 0 : pce_cnt + 1;
    pixel_ce <= (pce_cnt + 1 >= pce_div);
  end

  reg grcg_we = 0;
  reg [7:0] grcg_addr = 0, grcg_din = 0;
  wire grcg_expand;

  wire [15:0] egc_access_v = 16'h0000;
  wire [15:0] egc_fgbg_v   = 16'h0000;
  wire [15:0] egc_ope_v    = 16'h0000;
  wire [15:0] egc_fg_v     = 16'hFFFF;
  wire [15:0] egc_mask_v   = 16'hFFFF;
  wire [15:0] egc_bg_v     = 16'h0000;
  wire [15:0] egc_sft_v    = 16'h0000;
  wire [15:0] egc_leng_v   = 16'hFFFF;
  wire        egc_shift_we_v = 1'b0;

  wire [31:0] cpu_dout;
  wire [31:0] cpu_line_word;
  wire        cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  wire        gdc_mem_valid, gdc_mem_ready, gdc_mem_write;
  wire        gdc_mem_route_egc, gdc_mem_route_grcg, gdc_mem_page;
  wire [1:0]  gdc_mem_plane;
  wire [14:0] gdc_mem_offset;
  wire [31:0] gdc_mem_din, gdc_mem_rdata;
  wire [3:0]  gdc_mem_be;
  wire        gdc_mem_resp;

  // ==== DUT ====
  pc9821_gdc2 dut_gdc2 (
      .clk_sys(clk_sys), .rst_n_sys(rst_n_sys), .pixel_ce(pixel_ce),
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din),
      .io_dout(io_dout),
      .frame_end(1'b0), .cfg_snap(1'b0), .cfg_pending(1'b0),
      .vline(10'd0), .vtotal(10'd0), .m_vbp(6'd25), .display_page(1'b0),
      .stat_blank(1'b0), .stat_vsync(1'b0),
      .egc_mem_gate(1'b0), .grcg_cg_gate(grcg_expand),
      .access_page(1'b0),
      .mem_valid(gdc_mem_valid), .mem_ready(gdc_mem_ready),
      .mem_write(gdc_mem_write),
      .mem_route_egc(gdc_mem_route_egc), .mem_route_grcg(gdc_mem_route_grcg),
      .mem_page(gdc_mem_page), .mem_plane(gdc_mem_plane),
      .mem_offset(gdc_mem_offset), .mem_din(gdc_mem_din), .mem_be(gdc_mem_be),
      .mem_resp(gdc_mem_resp), .mem_rdata(gdc_mem_rdata),
      .gfx_line_addr(gfx_line_addr), .gfx_disp(gfx_disp), .pegc_256(1'b0)
  );

  pc9821_gvram_dut dut (
      .clk(clk_sys), .reset(!rst_n_sys),
      .access_page(1'b0),
      .win_plane(2'd0), .win_offset(15'd0),
      .cpu_din(32'd0), .cpu_be(4'd0), .cpu_line_read(1'b0),
      .cpu_valid(1'b0), .cpu_write(1'b0),
      .cpu_dout(cpu_dout), .cpu_line_word(cpu_line_word),
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_word_valid(cpu_line_word_valid),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din),
      .grcg_expand(grcg_expand),
      .egc_gate(1'b0),
      .egc_access(egc_access_v), .egc_fgbg(egc_fgbg_v), .egc_ope(egc_ope_v),
      .egc_fg(egc_fg_v), .egc_mask(egc_mask_v), .egc_bg(egc_bg_v),
      .egc_sft(egc_sft_v), .egc_leng(egc_leng_v), .egc_shift_we(egc_shift_we_v),
      .gdc_mem_valid(gdc_mem_valid), .gdc_mem_ready(gdc_mem_ready),
      .gdc_mem_write(gdc_mem_write),
      .gdc_mem_route_egc(gdc_mem_route_egc), .gdc_mem_route_grcg(gdc_mem_route_grcg),
      .gdc_mem_page(gdc_mem_page), .gdc_mem_plane(gdc_mem_plane),
      .gdc_mem_offset(gdc_mem_offset), .gdc_mem_din(gdc_mem_din),
      .gdc_mem_be(gdc_mem_be),
      .gdc_mem_resp(gdc_mem_resp), .gdc_mem_rdata(gdc_mem_rdata),
      .scan_enable(1'b0), .scan_line_tick(1'b0), .scan_page(1'b0),
      .scan_line_base(15'd0), .gfx_odd_line(1'b0),
      .line_rd_addr(7'd0), .line_rd_sel(1'b0)
  );

  integer errors = 0, checks = 0, seed = 12345;

  task automatic check(input cond, input [1023:0] what);
    begin
      checks = checks + 1;
      if (!cond) begin
        $display("MISMATCH %0s @ %0t", what, $time);
        errors = errors + 1;
      end
    end
  endtask

  // ==== THE BUS ====
  // The guest's writer: like the datasheet's protocol it waits while the FIFO is FULL
  // (status bit 1) before each byte.
  reg [7:0] st_last;
  task automatic io_read(input [7:0] a, output [7:0] d);
    begin
      @(negedge clk_sys); io_addr = a; io_rd = 1'b1;
      @(negedge clk_sys); io_rd = 1'b0;
      @(negedge clk_sys); d = io_dout;
    end
  endtask
  task automatic io_w(input [7:0] a, input [7:0] b);
    reg [7:0] st;
    begin
      io_read(8'hA0, st);
      while (st[1]) io_read(8'hA0, st);
      @(negedge clk_sys); io_addr = a; io_din = b; io_wr = 1'b1;
      @(negedge clk_sys); io_wr = 1'b0;
      @(negedge clk_sys);
    end
  endtask
  task automatic io_a2(input [7:0] b); io_w(8'hA2, b); endtask
  task automatic io_a0(input [7:0] b); io_w(8'hA0, b); endtask
  task automatic grcg_wr(input [7:0] a, input [7:0] d);
    begin
      @(negedge clk_sys); grcg_addr = a; grcg_din = d; grcg_we = 1'b1;
      @(negedge clk_sys); grcg_we = 1'b0;
      @(negedge clk_sys);
    end
  endtask
  // Wait for DRAWING to clear with the FIFO empty, then let the last posted store commit
  // (the bench peeks at the array, which a guest read never does).
  task automatic wait_done;
    reg [7:0] st;
    integer n;
    begin
      n = 0;
      io_read(8'hA0, st);
      while ((st[3] || !st[2]) && n < 50000000) begin n = n + 1; io_read(8'hA0, st); end
      st_last = st;
      repeat (64) @(negedge clk_sys);
    end
  endtask

  // ==== THE FIGURE PROGRAM (the datasheet's command shapes) ====
  task automatic prog(input [7:0] cmd, input [7:0] p1, input [13:0] dc, input [13:0] d,
                      input [13:0] d2, input [13:0] d1, input [13:0] dm,
                      input [15:0] ead, input [3:0] dad, input [63:0] ra,
                      input [3:0] zoom, input [1:0] rop);
    integer k;
    begin
      io_a2(8'h28 | {6'd0, rop});
      io_a2(8'h78);
      for (k = 0; k < 8; k = k + 1) io_a0(ra[63 - 8*k -: 8]);
      io_a2(8'h46); io_a0({4'd0, zoom});
      io_a2(8'h49); io_a0(ead[7:0]); io_a0(ead[15:8]); io_a0({dad, 4'd0});
      io_a2(8'h4C);
      io_a0(p1);
      io_a0(dc[7:0]); io_a0({2'd0, dc[13:8]});
      io_a0(d[7:0]);  io_a0({2'd0, d[13:8]});
      io_a0(d2[7:0]); io_a0({2'd0, d2[13:8]});
      io_a0(d1[7:0]); io_a0({2'd0, d1[13:8]});
      io_a0(dm[7:0]); io_a0({2'd0, dm[13:8]});
      io_a2(cmd);
    end
  endtask

  // ==== THE GVRAM (byte lanes; lane = GDC plane - 1) ====
  task automatic mem_wr(input [15:0] ea, input [15:0] v);   // ea = {GDC plane, word}
    reg [1:0] lane;
    reg [15:0] bo;
    begin
      lane = ea[15:14] - 2'd1;
      bo = {1'b0, ea[13:0], 1'b0};
      case (lane)
        2'd0: begin dut.u_gmem.mem0[bo] = v[7:0]; dut.u_gmem.mem0[bo | 16'd1] = v[15:8]; end
        2'd1: begin dut.u_gmem.mem1[bo] = v[7:0]; dut.u_gmem.mem1[bo | 16'd1] = v[15:8]; end
        2'd2: begin dut.u_gmem.mem2[bo] = v[7:0]; dut.u_gmem.mem2[bo | 16'd1] = v[15:8]; end
        default: begin dut.u_gmem.mem3[bo] = v[7:0]; dut.u_gmem.mem3[bo | 16'd1] = v[15:8]; end
      endcase
    end
  endtask
  function automatic [15:0] mem_rd(input [15:0] ea);
    reg [1:0] lane;
    reg [15:0] bo;
    begin
      lane = ea[15:14] - 2'd1;
      bo = {1'b0, ea[13:0], 1'b0};
      case (lane)
        2'd0: mem_rd = {dut.u_gmem.mem0[bo | 16'd1], dut.u_gmem.mem0[bo]};
        2'd1: mem_rd = {dut.u_gmem.mem1[bo | 16'd1], dut.u_gmem.mem1[bo]};
        2'd2: mem_rd = {dut.u_gmem.mem2[bo | 16'd1], dut.u_gmem.mem2[bo]};
        default: mem_rd = {dut.u_gmem.mem3[bo | 16'd1], dut.u_gmem.mem3[bo]};
      endcase
    end
  endfunction

  // ==== THE REFERENCE MODEL ====
  // refm[] is the expected GVRAM in the CPU's own bit order, indexed by the GDC's
  // {plane, word} EAD. The cursor (r_ead, r_mask) is the uPD7220's internal one: bit 0 of the
  // mask is the leftmost dot, which lands per-byte bit-reversed in CPU order (the Xe10's
  // GDCCURS MASK_0001 reads expected-cpu=0080).
  reg [15:0] refm [0:65535];
  reg [15:0] r_ead, r_mask, r_pat;
  reg [1:0]  r_rop;
  integer    r_route;      // 0 plain, 1 GRCG TDW, 2 GRCG RMW
  reg [7:0]  r_tile [0:3]; // B, R, G, E

  function automatic [15:0] rev16(input [15:0] w);
    integer q;
    begin
      for (q = 0; q < 8; q = q + 1) begin
        rev16[q] = w[7 - q];
        rev16[8 + q] = w[15 - q];
      end
    end
  endfunction

  // A dot (MAME write_vram's ROP of the pattern's bit through the mask, the Xe10's
  // FIGD_ROP rows; NP2kai gdcpset_prepare's GRCG/EGC routes paint only a 1 bit).
  integer model_dots = 0;   // dots the model painted with a 1 (a check cannot pass vacuously)
  task automatic r_plot(input bit_v);
    reg [15:0] m, col, old;
    integer p;
    begin
      if (bit_v) model_dots = model_dots + 1;
      m = rev16(r_mask);
      col = bit_v ? 16'hFFFF : 16'h0000;
      if (r_route == 0) begin
        old = refm[r_ead];
        case (r_rop)
          2'd0: refm[r_ead] = (old & ~m) | (col & m);
          2'd1: refm[r_ead] = old ^ (col & m);
          2'd2: refm[r_ead] = old & ~(col & m);
          default: refm[r_ead] = old | (col & m);
        endcase
      end else if (bit_v) begin
        // NP2kai gdc_pset.c withtdw (`*(UINT16 *)(ptr + VRAM_B) = grcg.tile[0].w` ...) and
        // withrmw (`ptr[VRAM_B] &= mask; ptr[VRAM_B] |= data & grcg.tile[0].b[0]` ...), at
        // the word the cursor addresses in every plane. Planes here are GDC planes:
        // 1 = B, 2 = R, 3 = G, 0 = E.
        for (p = 0; p < 4; p = p + 1) begin
          old = refm[{p[1:0], r_ead[13:0]}];
          if (r_route == 1)
            refm[{p[1:0], r_ead[13:0]}] = {r_tile[(p + 3) % 4], r_tile[(p + 3) % 4]};
          else
            refm[{p[1:0], r_ead[13:0]}] = (old & ~m) | (m & {r_tile[(p + 3) % 4], r_tile[(p + 3) % 4]});
        end
      end
    end
  endtask

  // MAME upd7220.cpp next_pixel (direction n: NP2kai gdc_sub.c vectdir[n] = {0,1},{1,1},
  // {1,0},{1,-1},{0,-1},{-1,-1},{-1,0},{-1,1}), the EAD carrying through its 16 bits.
  task automatic r_move(input [2:0] dr);
    begin
      if (dr == 3'd0 || dr == 3'd1 || dr == 3'd7) r_ead = r_ead + 16'd40;
      if (dr == 3'd3 || dr == 3'd4 || dr == 3'd5) r_ead = r_ead - 16'd40;
      if (dr == 3'd1 || dr == 3'd2 || dr == 3'd3) begin
        if (r_mask[15]) r_ead = r_ead + 16'd1;
        r_mask = {r_mask[14:0], r_mask[15]};
      end
      if (dr == 3'd5 || dr == 3'd6 || dr == 3'd7) begin
        if (r_mask[0]) r_ead = r_ead - 16'd1;
        r_mask = {r_mask[0], r_mask[15:1]};
      end
    end
  endtask

  // The pattern: bit 0 paints the next dot, rotating once per painted dot (NP2kai gdcpset).
  function automatic pbit(input integer dummy);
    pbit = r_pat[0];
  endfunction
  task automatic r_rot;
    r_pat = {r_pat[0], r_pat[15:1]};
  endtask

  function automatic integer sext14(input [13:0] v);
    sext14 = v[13] ? ($signed({18'h3FFFF, v})) : {18'd0, v};
  endfunction

  // NP2kai gdcsub_vectp: one dot.
  task automatic r_dot(input [2:0] dir);
    begin r_plot(pbit(0)); r_rot; r_move(dir); end
  endtask
  // MAME draw_line.
  task automatic r_line(input [2:0] oct, input [13:0] dc, input [13:0] dv, input [13:0] d1v,
                        input [13:0] d2v);
    integer i, d, d1, d2;
    reg [2:0] dr;
    begin
      d = sext14(dv); d1 = sext14(d1v); d2 = sext14(d2v);
      for (i = 0; i <= dc; i = i + 1) begin
        r_plot(pbit(0)); r_rot;
        if (oct[0]) dr = (d < 0) ? oct + 3'd1 : oct;
        else        dr = (d < 0) ? oct : oct + 3'd1;
        d = d + ((d < 0) ? d1 : d2);
        r_move(dr);
      end
    end
  endtask
  // MAME draw_rectangle, four sides (NP2kai gdcsub_vectr), a zero side 16384 dots long.
  task automatic r_rect(input [2:0] dir, input [13:0] dv, input [13:0] d2v);
    integer i, j, side_n;
    reg [2:0] dr;
    begin
      dr = dir;
      for (i = 0; i < 4; i = i + 1) begin
        side_n = (i & 1) ? d2v : dv;
        if (side_n == 0) side_n = 16384;
        for (j = 0; j < side_n; j = j + 1) begin
          r_plot(pbit(0)); r_rot;
          if (i > 0 && j == 0) dr = dr + 3'd2;
          r_move(dr);
        end
      end
    end
  endtask
  // MAME draw_char.
  task automatic r_char(input [2:0] dir, input slant, input [13:0] dc, input [13:0] dv,
                        input [63:0] ra, input [3:0] zoom);
    integer i, z, j, zd, di;
    reg [7:0] row;
    reg [15:0] p;
    reg [2:0] dr;
    reg b;
    begin
      dr = dir; di = 0;
      for (i = 0; i <= dc; i = i + 1) begin
        row = ra[8 * (i % 8) +: 8];     // ra = {RA8 .. RA15}: RA15 first, m_ra[15 - (i & 7)]
        p = {row, row};
        for (z = 0; z <= zoom; z = z + 1) begin
          for (j = 0; j < dv; j = j + 1) begin
            b = (di % 2) ? p[15 - (j % 16)] : p[j % 16];
            for (zd = 0; zd <= zoom; zd = zd + 1) begin
              r_plot(b);
              if (j != dv - 1 || zd != zoom) r_move(dr);
            end
          end
          dr = dr + (slant ? ((di % 2) ? 3'd5 : 3'd1) : ((di % 2) ? 3'd6 : 3'd2));
          r_move(dr);
          dr = dr + (slant ? ((di % 2) ? 3'd7 : 3'd3) : ((di % 2) ? 3'd6 : 3'd2));
          di = di + 1;
        end
      end
    end
  endtask
  // NP2kai gdcsub_vectc's circle, exact: at step i the dot sits i along the octant's axis
  // and s_i = round(r - sqrt(r^2 - i^2)) across it, r = D + 1; dots from step DM on.
  function automatic integer arc_s(input integer r, input integer i);
    real x;
    begin
      x = r - $sqrt(r * r - i * i);
      arc_s = $rtoi(x + 0.5);
    end
  endfunction
  task automatic r_arc(input [2:0] oct, input [13:0] dc, input [13:0] dv, input [13:0] dm);
    integer i, r, s0, s1;
    reg [2:0] ax, dg;
    begin
      r = dv + 1;
      // NP2kai's eight cases: octant 0 (x+s, y+i), 1 (x+i, y+s), 2 (x+i, y-s), 3 (x+s, y-i),
      // 4 (x-s, y-i), 5 (x-i, y-s), 6 (x-i, y+s), 7 (x-s, y+i): the axial step is direction
      // oct (even) / oct+1 (odd), the axial-plus-across step the other one.
      ax = oct[0] ? oct + 3'd1 : oct;
      dg = oct[0] ? oct : oct + 3'd1;
      for (i = 0; i <= dc; i = i + 1) begin
        if (i >= dm) begin r_plot(pbit(0)); r_rot; end
        s0 = arc_s(r, i); s1 = arc_s(r, i + 1);
        r_move((s1 == s0) ? ax : dg);
      end
    end
  endtask

  // ==== RUN ONE FIGURE AND COMPARE ====
  integer seeded_rand = 0;
  task automatic fill(input integer mode);   // 0 = zero, 1 = random
    integer e;
    reg [15:0] v;
    begin
      for (e = 0; e < 65536; e = e + 1) begin
        v = (mode == 1) ? $random(seed) : 16'h0000;
        refm[e] = v;
        mem_wr(e[15:0], v);
      end
    end
  endtask
  task automatic compare(input [1023:0] what);
    integer e, n;
    reg [15:0] g;
    reg [7:0] b0, b1;
    begin
      n = 0;
      for (e = 0; e < 65536; e = e + 1) begin
        g = mem_rd(e[15:0]);
        if (g !== refm[e]) begin
          if (n < 3) $display("  %0s: EAD %04x got %04x model %04x", what, e, g, refm[e]);
          n = n + 1;
        end
      end
      check(n == 0, what);
      io_a2(8'hE0); io_read(8'hA2, b0); io_read(8'hA2, b1);
      check({b1, b0} == r_ead, {what, " (cursor)"});
      check({dut_gdc2.gdc2_mask[1], dut_gdc2.gdc2_mask[0]} == r_mask, {what, " (mask)"});
      if ({b1, b0} != r_ead || {dut_gdc2.gdc2_mask[1], dut_gdc2.gdc2_mask[0]} != r_mask)
        $display("  %0s: cursor %04x/%04x model %04x/%04x", what, {b1, b0},
                 {dut_gdc2.gdc2_mask[1], dut_gdc2.gdc2_mask[0]}, r_ead, r_mask);
    end
  endtask

  // One figure: program it, run the model, wait, compare. `fig`: 0 dot, 1 line, 2 arc,
  // 3 rect, 4 char.
  task automatic figure(input [1023:0] what, input integer fig, input [2:0] dir,
                        input [13:0] dc, input [13:0] d, input [13:0] d2, input [13:0] d1,
                        input [13:0] dm, input [15:0] ead, input [3:0] dad,
                        input [63:0] ra, input [3:0] zoom, input [1:0] rop, input slant);
    reg [7:0] p1, cmd;
    begin
      case (fig)
        0: begin p1 = {5'd0, dir}; cmd = 8'h6C; end
        1: begin p1 = {5'b00001, dir}; cmd = 8'h6C; end
        2: begin p1 = {5'b00100, dir}; cmd = 8'h6C; end
        3: begin p1 = {5'b01000, dir}; cmd = 8'h6C; end
        default: begin p1 = {slant, 4'b0010, dir}; cmd = 8'h68; end
      endcase
      prog(cmd, p1, dc, d, d2, d1, dm, ead, dad, ra, zoom, rop);
      r_ead = ead; r_mask = 16'h0001 << dad; r_rop = rop;
      // FIGD's pattern is RA9:RA8 (NP2kai vectdraw `LOADINTELWORD(gdc.s.para + GDC_TEXTW)`).
      r_pat = {ra[55:48], ra[63:56]};
      case (fig)
        0: r_dot(dir);
        1: r_line(dir, dc, d, d1, d2);
        2: r_arc(dir, dc, d, dm);
        3: r_rect(dir, d, d2);
        default: r_char(dir, slant, dc, d, ra, zoom);
      endcase
      wait_done;
      compare(what);
    end
  endtask

  // The datasheet's line parameters for a vector (dx, dy) (NP2kai gdcsub_setvectl).
  task automatic line_params(input integer dx0, input integer dy0, output [2:0] oct,
                             output [13:0] dc, output [13:0] d, output [13:0] d1,
                             output [13:0] d2);
    integer dx, dy, t, ope;
    begin
      ope = 0;
      dy = (dy0 < 0) ? -dy0 : dy0;
      dx = dx0;
      if (dx == 0) ope = (dy0 >= 0) ? 7 : 3;
      else begin
        if (dx > 0) begin if (dy0 <= 0) ope = ope + 2; end
        else begin dx = -dx; ope = ope + 4; if (dy0 >= 0) ope = ope + 2; end
        if (ope & 2) begin if (dx <= dy) ope = ope + 1; end
        else begin if (dx >= dy) ope = ope + 1; end
      end
      if (!((ope + 1) & 2)) begin t = dx; dx = dy; dy = t; end
      oct = ope[2:0];
      dc = dx[13:0];
      d1 = (2 * dy);
      d = (2 * dy - dx);
      d2 = (2 * dy - 2 * dx);
    end
  endtask

  // ==== CHECKS ====
  initial begin : main
    integer k, n, r, dx, dy, t0, t1, pc0, pc1, busy_a, busy_b;
    reg [2:0] oct;
    reg [13:0] dc, d, d1, d2;
    reg [63:0] ra;
    reg [7:0] st, b0;
    reg saw_full, saw_notempty, saw_drawing;

    repeat (4) @(negedge clk_sys);
    rst_n_sys = 1;
    repeat (4) @(negedge clk_sys);
    r_route = 0;

    // ---- 1: arcs, all eight octants (NP2kai gdcsub_vectc's circle, r = D + 1) ----
    $display("CHECK 1: arcs in all eight octants");
    fill(0);
    for (k = 0; k < 8; k = k + 1) begin
      foreach_radius: begin
        integer ri;
        integer radii [0:6];
        radii[0] = 1; radii[1] = 2; radii[2] = 3; radii[3] = 7; radii[4] = 13; radii[5] = 40; radii[6] = 100;
        for (ri = 0; ri < 7; ri = ri + 1) begin
          n = $rtoi(radii[ri] / 1.41421356);   // DC = r sin 45 (NP2kai m = r / sqrt 2)
          figure("arc", 2, k[2:0], n[13:0], radii[ri] - 1, 2 * (radii[ri] - 1), 14'h3FFF, 14'd0,
                 16'h8000 + 16'd200 * 40 + 16'd20, 4'd8, 64'hFFFF_0000_0000_0000, 4'd0, 2'd1, 1'b0);
        end
      end
    end
    // a start step DM and a rotating pattern (dots before DM paint nothing and rotate nothing)
    figure("arc DM", 2, 3'd1, 14'd60, 14'd99, 14'd198, 14'h3FFF, 14'd25,
           16'h8000 + 16'd200 * 40 + 16'd20, 4'd3, 64'hA53C_0000_0000_0000, 4'd0, 2'd3, 1'b0);
    figure("arc DM oct 6", 2, 3'd6, 14'd30, 14'd49, 14'd98, 14'h3FFF, 14'd9,
           16'h8000 + 16'd200 * 40 + 16'd20, 4'd11, 64'hF0F0_0000_0000_0000, 4'd0, 2'd0, 1'b0);

    check(model_dots > 900, "the arcs painted dots");

    // ---- 2: random figures on random GVRAM, all four ROPs ----
    $display("CHECK 2: random lines, rectangles, characters and dots");
    for (k = 0; k < 96; k = k + 1) begin
      fill(1);
      r = $random(seed);
      ra = {$random(seed), $random(seed)};
      case (k % 4)
        0: begin   // a line from the datasheet's parameters
          dx = ($random(seed) % 120); dy = ($random(seed) % 120);
          line_params(dx, dy, oct, dc, d, d1, d2);
          figure("line", 1, oct, dc, d, d2, d1, 14'h3FFF,
                 16'h4000 + 16'd200 * 40 + 16'd20 + (r[7:0]), r[11:8], ra, 4'd0, r[13:12], 1'b0);
        end
        1: figure("rect", 3, r[2:0], 14'd3, 14'd1 + r[9:4], 14'd1 + r[15:10], 14'h3FFF, 14'd0,
                  16'hC000 + 16'd200 * 40 + 16'd20, r[19:16], ra, 4'd0, r[21:20], 1'b0);
        2: figure("char", 4, r[2:0], {11'd0, r[5:3]} + 14'd1, {10'd0, r[9:6]} + 14'd1, 14'd0,
                  14'h3FFF, 14'h3FFF, 16'h8000 + 16'd200 * 40 + 16'd20, r[13:10], ra,
                  {2'd0, r[15:14]}, r[17:16], r[18]);
        default: figure("dot", 0, r[2:0], 14'd0, 14'd8, 14'd8, 14'h3FFF, 14'h3FFF,
                        16'h0000 + r[15:0] % 16'h4000, r[19:16], ra, 4'd0, r[21:20], 1'b0);
      endcase
    end

    // ---- 3: a figure walks off its plane into the next one ----
    // The Xe10's runaway rectangles (GDCDRAW RECT_1x1_*) change exactly the word counts a
    // 16-bit {plane, word} walk predicts; the model carries the same way.
    $display("CHECK 3: plane carry");
    fill(0);
    model_dots = 0;
    figure("down past plane R's end", 1, 3'd0, 14'd20, 14'h3FEC, 14'h3FD8, 14'd0, 14'h3FFF,
           16'hBFD0, 4'd2, 64'hFFFF_0000_0000_0000, 4'd0, 2'd3, 1'b0);
    figure("right past 0xFFFF", 1, 3'd2, 14'd40, 14'h3FD7, 14'h3FAE, 14'd0, 14'h3FFF,
           16'hFFFE, 4'd0, 64'hFFFF_0000_0000_0000, 4'd0, 2'd3, 1'b0);

    check(model_dots == 21 + 41, "the plane-carry lines painted every dot");
    check(mem_rd(16'hC020) != 16'h0000, "the line reached plane G's first rows");
    check(mem_rd(16'h0000) != 16'h0000, "the line wrapped from 0xFFFF to EAD 0x0000");

    // ---- 4: the GRCG routes (NP2kai withtdw / withrmw) ----
    $display("CHECK 4: GRCG TDW and RMW");
    fill(1);
    r_tile[0] = 8'h33; r_tile[1] = 8'h55; r_tile[2] = 8'h0F; r_tile[3] = 8'hC3;
    grcg_wr(8'h7C, 8'h80);
    grcg_wr(8'h7E, 8'h33); grcg_wr(8'h7E, 8'h55); grcg_wr(8'h7E, 8'h0F); grcg_wr(8'h7E, 8'hC3);
    r_route = 1;
    line_params(37, 11, oct, dc, d, d1, d2);
    figure("GRCG TDW line", 1, oct, dc, d, d2, d1, 14'h3FFF, 16'h8000 + 16'd100 * 40 + 16'd7,
           4'd5, 64'hCFF3_0000_0000_0000, 4'd0, 2'd0, 1'b0);
    grcg_wr(8'h7C, 8'hC0);
    grcg_wr(8'h7E, 8'h33); grcg_wr(8'h7E, 8'h55); grcg_wr(8'h7E, 8'h0F); grcg_wr(8'h7E, 8'hC3);
    r_route = 2;
    line_params(-29, 23, oct, dc, d, d1, d2);
    figure("GRCG RMW line", 1, oct, dc, d, d2, d1, 14'h3FFF, 16'h8000 + 16'd100 * 40 + 16'd17,
           4'd9, 64'h0FFF_0000_0000_0000, 4'd0, 2'd0, 1'b0);
    grcg_wr(8'h7C, 8'h00);
    r_route = 0;

    // ---- 5: FIGD resets the FIGS block (NP2kai gdc_vectreset): a WRITE after it is one unit ----
    $display("CHECK 5: FIGS defaults after a figure");
    fill(0);
    // (a dot ignores DC: programming DC = 7 shows the reset clears it, not the program)
    figure("dot before the reset check", 0, 3'd2, 14'd7, 14'd8, 14'd8, 14'h3FFF, 14'h3FFF,
           16'h8800, 4'd0, 64'hFFFF_0000_0000_0000, 4'd0, 2'd3, 1'b0);
    check({dut_gdc2.gdc2_vect[2], dut_gdc2.gdc2_vect[1]} == 16'h0000, "FIGS DC reset to 0");
    check({dut_gdc2.gdc2_vect[4], dut_gdc2.gdc2_vect[3]} == 16'h0008, "FIGS D reset to 8");
    check({dut_gdc2.gdc2_vect[6], dut_gdc2.gdc2_vect[5]} == 16'h0008, "FIGS D2 reset to 8");
    check({dut_gdc2.gdc2_vect[8], dut_gdc2.gdc2_vect[7]} == 16'hFFFF, "FIGS D1 reset to all ones");
    check({dut_gdc2.gdc2_vect[10], dut_gdc2.gdc2_vect[9]} == 16'hFFFF, "FIGS DM reset to all ones");
    io_a2(8'h4A); io_a0(8'hFF); io_a0(8'hFF);        // MASK FFFF
    io_a2(8'h23); io_a0(8'hFF); io_a0(8'hFF);        // WRITE SET FFFF: DC = 0, ONE word
    wait_done;
    // the cursor is at 0x8800 + one dot right (the dot's own advance); one unit paints it
    check(mem_rd(16'h8800) == 16'hFFFF, "the WRITE painted its word");
    check(mem_rd(16'h8801) == 16'h0000, "the WRITE painted ONE word (DC reset to 0)");

    // ---- 6: GCHRD without GC draws its FIGS figure with RA15 doubled (NP2kai textdraw) ----
    $display("CHECK 6: GCHRD with a line flag");
    fill(0);
    prog(8'h68, 8'h0A, 14'd31, 14'h3FE1, 14'h3FC2, 14'd0, 14'h3FFF, 16'h8000 + 16'd50 * 40,
         4'd0, 64'h0000_0000_0000_0081, 4'd0, 2'd3);
    r_ead = 16'h8000 + 16'd50 * 40; r_mask = 16'h0001; r_rop = 2'd3; r_pat = 16'h8181;
    r_line(3'd2, 14'd31, 14'h3FE1, 14'd0, 14'h3FC2);
    wait_done;
    compare("GCHRD line, pattern RA15:RA15");

    // ---- 7: CSRW's dAD reloads the mask after a MASK (Xe10 GDCCURS MASK_THEN_CURS_05) ----
    $display("CHECK 7: CSRW reloads the one-hot mask");
    io_a2(8'h4A); io_a0(8'h5A); io_a0(8'hA5);
    check({dut_gdc2.gdc2_mask[1], dut_gdc2.gdc2_mask[0]} == 16'hA55A, "MASK A55A");
    io_a2(8'h49); io_a0(8'h00); io_a0(8'h88); io_a0(8'h50);
    check({dut_gdc2.gdc2_mask[1], dut_gdc2.gdc2_mask[0]} == 16'h0020, "CSRW dAD 5 -> mask 0020");

    // ---- 8: the command FIFO keeps order, with its status bits ----
    $display("CHECK 8: the command FIFO");
    fill(0);
    // figure A: a long horizontal line; figure B's whole program is written while A draws
    prog(8'h6C, 8'h0A, 14'd400, 14'h3E70, 14'h3CE0, 14'd0, 14'h3FFF, 16'h8000 + 16'd20 * 40,
         4'd0, 64'hFFFF_0000_0000_0000, 4'd0, 2'd3);
    saw_full = 0; saw_notempty = 0; saw_drawing = 0;
    // 16 bytes behind the draw: a TEXTW block (9) and a CSRW (4) and 3 of FIGS...
    for (k = 0; k < 16; k = k + 1) begin
      @(negedge clk_sys); io_addr = (k == 0 || k == 9 || k == 13) ? 8'hA2 : 8'hA0;
      io_din = (k == 0) ? 8'h78 : (k == 9) ? 8'h49 : (k == 13) ? 8'h4C :
               (k < 9) ? 8'hFF : (k == 10) ? 8'h00 : (k == 11) ? 8'h82 :
               (k == 12) ? 8'h00 : (k == 14) ? 8'h08 : 8'h00;
      io_wr = 1'b1;
      @(negedge clk_sys); io_wr = 1'b0;
      io_read(8'hA0, st);
      if (st[3]) saw_drawing = 1;
      if (!st[2]) saw_notempty = 1;
    end
    io_read(8'hA0, st);
    saw_full = st[1];
    check(saw_drawing, "DRAWING (bit 3) while A draws");
    check(saw_notempty, "FIFO EMPTY (bit 2) clear with bytes queued");
    check(saw_full, "FIFO FULL (bit 1) at 16 queued bytes");
    // ...and the rest of B's program, the writer waiting on FULL
    // (FIGS so far: P1 = 0x08, a line in direction 0, and DC's low byte 0.) The other nine.
    for (k = 0; k < 9; k = k + 1) io_a0(8'h00);
    io_a2(8'h6C);
    // the model: A, then B (a one-dot line, dir 0, at 0x8200 dAD 0, the all-ones pattern)
    r_ead = 16'h8000 + 16'd20 * 40; r_mask = 16'h0001; r_rop = 2'd3; r_pat = 16'hFFFF;
    r_line(3'd2, 14'd400, 14'h3E70, 14'd0, 14'h3CE0);
    r_ead = 16'h8200; r_mask = 16'h0001; r_pat = 16'hFFFF;
    r_line(3'd0, 14'd0, 14'd0, 14'd0, 14'd0);
    wait_done;
    compare("figure B after A, through the FIFO");

    // ---- 9: one step per 14 dot clocks, independent of clk_sys ----
    // A 64-dot line timed in pixel_ce enables at two pixel_ce / clk_sys ratios. The pace is
    // FIG_PACE + 1 = 14 dot clocks a step: faster than the Xe10's 29.5 (GDCTIME) and
    // NP2kai's 15.2 (calc_gdcslavewait 0.72 us at 21.0526 MHz).
    $display("CHECK 9: the step pace in dot clocks");
    begin : timing
      integer div;
      for (div = 4; div <= 6; div = div + 2) begin
        pce_div = div;
        fill(0);
        prog(8'h6C, 8'h0A, 14'd63, 14'h3FC1, 14'h3F82, 14'd0, 14'h3FFF, 16'h8000 + 16'd30 * 40,
             4'd0, 64'hFFFF_0000_0000_0000, 4'd0, 2'd3);
        // count pixel_ce enables while DRAWING is up (from the FIGD on)
        pc0 = 0;
        @(negedge clk_sys);
        while (dut_gdc2.gdc2_drawing) begin
          if (pixel_ce) pc0 = pc0 + 1;
          @(negedge clk_sys);
        end
        if (div == 4) busy_a = pc0; else busy_b = pc0;
        repeat (64) @(negedge clk_sys);
      end
      pce_div = 1;
      $display("NOTE busy dot clocks for 64 dots: %0d (pixel_ce 1/4), %0d (1/6)", busy_a, busy_b);
      check(busy_a == busy_b, "the busy time in dot clocks does not depend on clk_sys");
      check(busy_a >= 64 * 14 - 2 && busy_a <= 64 * 14 + 2, "64 steps of 14 dot clocks");
      check(busy_a * 100 < 64 * 1516, "faster than NP2kai's 0.72 us per dot");
    end

    // ==== VERDICT ====
    $display("NOTE gdc2_figure: %0d checks, %0d errors", checks, errors);
    if (errors == 0) begin
      $display("TB_PC9821_GDC2_FIGURE: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_GDC2_FIGURE: FAIL (%0d errors over %0d checks)", errors, checks);
    end
  end

  initial begin
    #2_000_000_000;
    $fatal(1, "TB_PC9821_GDC2_FIGURE: TIMEOUT");
  end
endmodule
