`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_TRAM_ADDR_EQUIV: the CYCLE-EXACT EQUIVALENCE contract for the text fetch address - the REFACTOR pin for the pc9821_crtc timing seam (an 80 MHz fit's worst path, v_sync[2][5] -> the text-RAM port-B address register), a CHARACTERIZATION against the documented semantics and not a hardware claim (the hardware behaviour stays in the reference-derived benches): tram_vid_addr is bit-identical EVERY clk_sys cycle to a golden address computed in the bench from the SYNC field map/clamp, the documented fetch schedule and the cfg_snap/cfg_pending snapshot semantics, every mux arm included (the walker arm is combinational and keeps its priority, so a registered walker address cannot hide behind an equal value), over frames with mid-frame register writes, writes straddling the frame_end snapshot edge (the epoch-defer window), frame-boundary SYNC swaps, 40/80-column swaps and irregular pixel_ce gaps; the arm selects and f_wordidx at its consuming dots are bit-identical, and the render captures (r_wordidx, r_raster) never move. It also pins the odd-sync-parity premises by name (geom-shared-bit-identity: HTOTAL/VTOTAL/HACTIVE/VACTIVE and the o_htotal/o_vtotal/o_vline outputs are the documented field map at every cycle - the single shared source the fetch walker, pc9821_gdc2's wrapped display-line parity and the feed_odd/at_line_tick expression must all read together, never a mix of live and registered; linetick-dot-outside-active: HACTIVE <= HTOTAL-8 so the line-tick dot stays outside the mixer's active window).
//
// TB_PC9821_TRAM_ADDR_EQUIV: a CYCLE-EXACT EQUIVALENCE bench for the text fetch address -
// the REFACTOR CONTRACT for the pc9821_crtc timing seam (the fitted lightoc build's worst
// path, v_sync[2][5] -> the text-RAM port-B address register), pinned as a characterization
// against the documented semantics and NOT as a hardware claim: the hardware behaviour lives
// in the reference-derived benches (tb_pc9821_gdc_text, tb_pc9821_gdc_sync_raster, ...) and
// must stay green beside this one.
//
// THE CONTRACTS, asserted by NAME:
//  [walker-arm-priority] tram_vid_addr is bit-identical EVERY clk_sys cycle to a golden
//     address the bench computes from the documented fetch semantics (the field map and
//     clamp in pc9821_crtc's geometry section, the fetch schedule in its pipeline header,
//     and the frame-boundary configuration snapshot of the cfg_snap/cfg_pending handshake) -
//     every arm of the mux included: the walker arm (wk_tr_read has priority and is
//     COMBINATIONAL from its inputs so it is on the port DURING the dot that presents it),
//     the three scanout fetch arms and the default. Driven over frames with mid-frame
//     register writes, writes straddling the frame-boundary snapshot edge (the epoch-defer
//     window), frame-boundary SYNC swaps, 40/80-column swaps, display blanks, irregular
//     pixel_ce gaps, odd-VTOTAL blocks (441 lines: VTOTAL[0] and the vline+2 >= VTOTAL
//     wrap) and a VACTIVE = VTOTAL-1 block whose walk-slot early copy surfaces on ACTIVE
//     consuming dots.
//  [fetch-arm-select] txt_on/fetch_lo/fetch_hi/fetch_at are bit-identical every cycle, so
//     the arm the mux selects is the documented one and a registered walker address (which
//     would arrive a dot late) cannot hide behind an equal address value.
//  [wordidx-consume] f_wordidx is bit-identical at every CONSUMING dot (the three fetch dots
//     and cell_done, where r_wordidx latches it). At non-consuming dots the mux masks
//     f_wordidx entirely - that is exactly the window a one-dot-early precompute register is
//     allowed to differ in, and [walker-arm-priority] proves the port never shows it.
//  [capture-r-wordidx] / [capture-r-raster] the render captures (r_wordidx, r_raster) are
//     bit-identical every cycle to the golden capture model, so nothing that reaches a
//     register may move either.
//  [geom-shared-bit-identity] HTOTAL/VTOTAL/HACTIVE/VACTIVE are bit-identical every cycle to
//     the golden field map of the FRAME-BOUNDARY-SAMPLED v_sync image - and o_htotal /
//     o_vtotal / o_vline are the SAME values (the same wires) the raster counts on. This is
//     the reviewed odd-sync-parity contract's premise: feed_odd's
//     crtc expression and pc9821_gdc2's wrapped display-line parity v_oline[0] are equal as
//     functions of (vline, VTOTAL), and both read these wires - so their bit-identity at
//     every dot survives any restructure that keeps this assertion green and wires both
//     expressions to these wires. If a registered geometry copy is introduced it MUST feed
//     the fetch walker, gdc2's v_oline wrap (through o_vtotal) and the feed_odd/at_line_tick
//     expression TOGETHER; this assertion is what says the shared value is still the
//     documented one at every dot, never early and never late.
//  [linetick-dot-outside-active] HACTIVE <= HTOTAL - 8 every cycle, so the gvram line-tick
//     dot (hdot == HTOTAL - 1) the parity fix's one-dot mux window contains is always
//     outside the mixer's active window (parity contract invariant 3).
//
// THE GOLDEN MODEL never reads the DUT: it computes the raster counters, the SYNC field map
// and clamp, the fetch coordinates and the cfg snapshot from the bench's own state, which it
// advances by the DOCUMENTED register semantics (the writes it drives itself). Only the
// addresses and the named signals above are compared.
//
// WHAT IT IS BLIND TO, stated: it is not a hardware-behaviour bench (no NP2kai values are
// asserted here), it does not check the pixel pipeline past the fetch latches, and it does
// not check pc9821_gdc2 itself - the parity identity's algebraic premise is pinned here and
// the identity itself is the parity lane's bench, asserted against these same wires.

module tb_pc9821_tram_addr_equiv;
  reg clk_sys = 0;
  always #5 clk_sys = ~clk_sys;   // 100 MHz gating clock; pixel_ce decides the dot rate

  reg rst_n = 0;
  reg pixel_ce = 1'b1;

  reg        io_wr = 1'b0;
  reg        io_rd = 1'b0;
  reg [7:0]  io_addr = 8'h00;
  reg [7:0]  io_din = 8'h00;
  wire [7:0] io_dout;
  wire [10:0] gdc_ff2_state;

  reg [13:0] tram_cpu_addr = 14'd0;
  reg [7:0]  tram_cpu_din = 8'h00;
  reg        tram_cpu_we = 1'b0;
  wire [7:0] tram_cpu_dout;

  reg        wk_tr_read = 1'b0;
  reg [13:0] wk_tr_addr = 14'd0;
  wire [7:0] o_tram_vid_q;

  wire [10:0] ank_rd_addr;
  wire [15:0] ank_word = 16'h0000;      // parked: the font stores are not this bench's
  wire [1:0]  jc_rd_bank;
  wire [6:0]  jc_rd_cell;
  wire [1:0]  jc_rd_word;
  wire [31:0] jc_rd_q = 32'h0000_0000;
  wire [12:0] cg_ram_vid_addr;
  wire [7:0]  cg_ram_vid_q = 8'h00;

  wire [7:0]  o_v_pitch;
  wire        o_v_col40;
  wire [15:0] o_v_sad;
  wire        o_v_row0_stale;
  wire [9:0]  o_vline, o_hdot, o_htotal, o_vtotal;
  wire        o_frame_end, o_cfg_snap, o_cfg_pending;
  wire        o_display_page, o_stat_blank, o_stat_vsync;
  wire        vsync_active, vsync_edge, vsync_irq, disp_on;
  reg         vsync_irq_arm = 1'b0;
  wire        gfx_access_page, gfx_egc_gate;
  wire [15:0] dbg_sad;
  wire [7:0]  dbg_pitch;
  wire        dbg_col40, dbg_disp;
  wire        text_opaque, text_cell;
  wire [11:0] text_colour;
  wire [9:0]  pix_dot;
  wire        pix_h_active, pix_v_active, gfx_odd_line, gfx_mode16;
  wire [31:0] gfx_dig;
  wire        pal_wr_en, pal_commit;
  wire [3:0]  pal_wr_idx, pal_wr_data;
  wire [1:0]  pal_wr_chan;
  wire        hs_out, vs_out, de_out;

  // ==== DUT ====
  pc9821_crtc dut (
      .crt31k(1'b0),   // 0x09A8 bit 0 clear: the 24 kHz monitor range
      .gfx_win_on(1'b0),   // no slave window here
      .clk_sys(clk_sys), .rst_n_sys(rst_n), .rst_n_vid(rst_n), .pixel_ce(pixel_ce),
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din), .io_dout(io_dout),
      .gdc_ff2_state(gdc_ff2_state),
      .tram_cpu_addr(tram_cpu_addr), .tram_cpu_din(tram_cpu_din),
      .tram_cpu_we(tram_cpu_we), .tram_cpu_dout(tram_cpu_dout),
      .wk_tr_read(wk_tr_read), .wk_tr_addr(wk_tr_addr), .o_tram_vid_q(o_tram_vid_q),
      .ank_rd_addr(ank_rd_addr), .ank_word(ank_word),
      .jc_rd_bank(jc_rd_bank), .jc_rd_cell(jc_rd_cell),
      .jc_rd_word(jc_rd_word), .jc_rd_q(jc_rd_q),
      .cg_ram_vid_addr(cg_ram_vid_addr), .cg_ram_vid_q(cg_ram_vid_q),
      .o_v_pitch(o_v_pitch), .o_v_col40(o_v_col40), .o_v_sad(o_v_sad),
      .o_v_row0_stale(o_v_row0_stale),
      .o_vline(o_vline), .o_hdot(o_hdot), .o_htotal(o_htotal), .o_vtotal(o_vtotal),
      .o_frame_end(o_frame_end), .o_cfg_snap(o_cfg_snap), .o_cfg_pending(o_cfg_pending),
      .o_display_page(o_display_page), .o_stat_blank(o_stat_blank), .o_stat_vsync(o_stat_vsync),
      .vsync_active(vsync_active), .vsync_edge(vsync_edge),
      .vsync_irq_arm(vsync_irq_arm), .vsync_irq(vsync_irq),
      .disp_on(disp_on), .gfx_access_page(gfx_access_page), .gfx_egc_gate(gfx_egc_gate),
      .dbg_sad(dbg_sad), .dbg_pitch(dbg_pitch), .dbg_col40(dbg_col40), .dbg_disp(dbg_disp),
      .text_opaque(text_opaque), .text_cell(text_cell), .text_colour(text_colour),
      .pix_dot(pix_dot), .pix_h_active(pix_h_active), .pix_v_active(pix_v_active),
      .gfx_odd_line(gfx_odd_line),
      .gfx_mode16(gfx_mode16), .gfx_dig(gfx_dig),
      .pal_wr_en(pal_wr_en), .pal_wr_idx(pal_wr_idx),
      .pal_wr_chan(pal_wr_chan), .pal_wr_data(pal_wr_data), .pal_commit(pal_commit),
      .hs_out(hs_out), .vs_out(vs_out), .de_out(de_out)
  );

  // =====================================================================
  // GOLDEN MODEL STATE - the documented register semantics of pc9821_crtc
  // (the CPU-side command capture, the cfg dirty/ack/epoch snapshot handshake,
  // the sync_live -> v_sync frame-boundary copy and the raster counters).
  // =====================================================================
  // CPU-side
  reg [7:0] m_mode1;        // MODE FF1 (0x68 bit set form)
  reg       m_gdc_start;    // BCTRL/START and the SYNC-on form
  reg [7:0] m_pitch;        // the PITCH command's one parameter (odd bit dropped)
  reg [7:0] m_pram0, m_pram1;  // PRAM screen 0's {sad_lo, sad_hi}
  reg [7:0] m_slive[0:7];   // the SYNC block as it arrives (sync_live)
  reg       m_sync_pending;
  reg [2:0] m_sync_cnt;
  reg       m_cmd_active;
  reg [7:0] m_cur_cmd;
  reg [2:0] m_param_cnt;
  // cfg handshake
  reg       m_cfg_data_d, m_cfg_dirty, m_cfg_ack, m_cfg_ack_seen;
  reg [7:0] m_cfg_epoch, m_cfg_epoch_snap;
  reg [1:0] m_cfg_ack_sync;
  // raster-side copies
  reg [7:0] m_vsync[0:7];   // v_sync: the frame-boundary copy of the block
  reg [1:0] m_cfg_dirty_sync;
  reg       m_v_disp, m_v_col40;
  reg [7:0] m_v_pitch, m_v_sad_lo, m_v_sad_hi;
  // counters and captures
  reg [9:0]  m_hdot, m_vline;
  reg [15:0] m_r_wordidx;
  reg [3:0]  m_r_raster;
  reg        m_col40_x;   // the snapshot copy of mode1[2] the scanout runs on
  integer    m_i;

  // The command parameter counts (NP2kai gdc_cmd.tbl's outdatas column, as the RTL states
  // them): only the capture DEPTH matters here, so a 0x70 PRAM command still eats four
  // bytes even though two are kept.
  function [3:0] cmd_params(input [7:0] c);
    case (c)
      8'h06:                      cmd_params = 4'd1;
      8'h47:                      cmd_params = 4'd1;
      8'h49:                      cmd_params = 4'd3;
      8'h4B:                      cmd_params = 4'd3;
      8'h0E, 8'h0F:               cmd_params = 4'd8;
      8'h70, 8'h74, 8'h78, 8'h7C: cmd_params = 4'd4;
      default:                    cmd_params = 4'd0;
    endcase
  endfunction

  // =====================================================================
  // GOLDEN COMPUTE - geometry, fetch cone and expected address, from the
  // documented field map / clamp / fetch schedule. Runs once per check on
  // the model's CURRENT state (which is the state the coming posedge sees).
  // =====================================================================
  integer g_htotal, g_vtotal, g_hactive, g_vactive;
  integer m_frame_end, m_wk_cfg_snap, m_early_copy, m_snap_copy;
  integer m_wk_slot;
  integer m_last_cell, m_f_line, m_f_row, m_f_raster, m_rowbase;
  integer m_wordidx, m_txt_on, m_cell_end;
  integer m_f_lo, m_f_hi, m_f_at, m_f_fo, m_cell_done, m_wrapped_fetch;
  reg [13:0] exp_addr;

  // ==== CHECKS ====
  task automatic compute_golden;
    integer tmp, tmp2, cr, hs_f, hfp_f, vs_f, vfp_f, vbp_f, lf, vfbs;
    integer x_raw, x, y_raw, y, hact8, hactmax;
    integer c40, c80, off, sad, idx;
    begin
      // ---- the SYNC field map (para[] in arrival order) and the clamp ----
      tmp   = m_vsync[2] | (m_vsync[3] << 8);       // word(para[2..3])
      tmp2  = m_vsync[6] | (m_vsync[7] << 8);       // word(para[6..7])
      cr    = m_vsync[1] + 2;
      hs_f  = tmp & 31;
      vs_f  = (tmp >> 5) & 31;
      hfp_f = (tmp >> 10) + (m_vsync[4] & 63);      // the two hfp fields sum
      vfp_f = m_vsync[5] & 63;
      vbp_f = (tmp2 >> 10) & 63;
      lf    = tmp2 & 1023;
      lf    = (lf == 0) ? 1024 : lf;                // ((tmp2-1)&0x3ff)+1 as 11 bits: 0 -> 1024
      vfbs  = vs_f + vfp_f + vbp_f;
      if (vfbs == 0) vfbs = 1;                      // `if (!vfbs) vfbs = 1`
      x_raw = cr + hs_f + hfp_f + 3;                // 3 = NP2kai's h back porch
      x     = (x_raw < 100) ? 100 : (x_raw > 112) ? 112 : x_raw;
      y_raw = lf + vfbs;
      y     = (y_raw < 400) ? 400 : (y_raw > 575) ? 575 : y_raw;
      g_htotal  = 8 * x;
      g_vtotal  = y;
      hact8     = 8 * cr;
      hactmax   = g_htotal - 8;
      g_hactive = (hact8 > hactmax) ? hactmax : hact8;
      g_vactive = (lf > (g_vtotal - 1)) ? (g_vtotal - 1) : lf;

      // ---- the snapshot events of THIS dot (documented cfg semantics) ----
      m_wk_slot    = (g_vtotal - 1) & 10'h3F0;
      m_frame_end  = (m_vline == g_vtotal - 1) && (m_hdot == g_htotal - 1);
      m_wk_cfg_snap = (m_vline == m_wk_slot - 1) && (m_hdot == g_htotal - 1);
      m_early_copy = m_wk_cfg_snap && m_cfg_dirty_sync[1];
      m_snap_copy  = m_frame_end && m_cfg_dirty_sync[1];

      // ---- the fetch cone (the documented fetch schedule) ----
      m_last_cell = m_col40_x ? ((m_hdot >> 4) == 39) : ((m_hdot >> 3) == 79);
      c40 = m_last_cell ? 0 : (((m_hdot >> 4) + 1) & 63);
      c80 = m_last_cell ? 0 : (((m_hdot >> 3) + 1) & 127);
      // f_line: the NEXT line's coordinates at the line's last cell (the wrap cell fetches
      // the next line's column 0, and at vline == VACTIVE-1 that is row 0 of the frame).
      m_f_line = m_last_cell
               ? ((m_vline == g_vactive - 1) ? 0 : ((m_vline + 1) & 1023))
               : m_vline;
      m_f_row    = (m_f_line >> 4) & 31;
      m_f_raster = m_f_line & 15;
      sad        = (m_v_sad_hi << 8) | m_v_sad_lo;
      m_rowbase  = (m_f_row * m_v_pitch) & 65535;
      off        = m_col40_x ? (c40 << 1) : c80;
      idx        = (m_rowbase + off + sad) & 65535;
      m_wordidx  = idx;

      // ---- the documented fetch dots and the mux ----
      m_txt_on    = (m_hdot < g_hactive) && (m_vline < g_vactive) && m_v_disp;
      m_cell_end  = m_col40_x ? ((m_hdot & 15) == 15) : ((m_hdot & 7) == 7);
      m_cell_done = m_txt_on && m_cell_end;
      m_f_lo = m_txt_on && (m_col40_x ? ((m_hdot & 15) == 11) : ((m_hdot & 7) == 3));
      m_f_hi = m_txt_on && (m_col40_x ? ((m_hdot & 15) == 12) : ((m_hdot & 7) == 4));
      m_f_at = m_txt_on && (m_col40_x ? ((m_hdot & 15) == 13) : ((m_hdot & 7) == 5));
      m_f_fo = m_txt_on && (m_col40_x ? ((m_hdot & 15) == 14) : ((m_hdot & 7) == 6));
      m_wrapped_fetch = m_last_cell && (m_vline == g_vactive - 1) &&
                        (m_f_lo || m_f_hi || m_f_at);
      exp_addr = wk_tr_read ? wk_tr_addr
               : m_f_lo ? {1'b0, idx[11:0], 1'b0}
               : m_f_hi ? {1'b0, idx[11:0], 1'b1}
               : m_f_at ? {1'b1, idx[11:0], 1'b0}
               : 14'h0000;
    end
  endtask

  // =====================================================================
  // MODEL STATE UPDATE - mirrors the documented register semantics. The
  // golden compute ran at the previous negedge on THIS state, so its
  // geometry/frame_end flags describe exactly the values this edge sees.
  // =====================================================================
  always @(posedge clk_sys) begin
    if (!rst_n) begin
      m_mode1 <= 8'h98;   // MODE FF1's power-on value (verified)
      m_gdc_start <= 1'b0;
      m_pitch <= 8'd80;
      m_pram0 <= 8'h00;
      m_pram1 <= 8'h00;
      m_slive[0] <= 8'h10; m_slive[1] <= 8'h4e; m_slive[2] <= 8'h07; m_slive[3] <= 8'h25;
      m_slive[4] <= 8'h07; m_slive[5] <= 8'h07; m_slive[6] <= 8'h90; m_slive[7] <= 8'h65;
      m_sync_pending <= 1'b0;
      m_sync_cnt <= 3'd0;
      m_cmd_active <= 1'b0;
      m_cur_cmd <= 8'h00;
      m_param_cnt <= 3'd0;
      m_cfg_data_d <= 1'b0;
      m_cfg_dirty <= 1'b1;   // force the power-on snapshot at the first frame
      m_cfg_ack <= 1'b0;
      m_cfg_ack_seen <= 1'b0;
      m_cfg_ack_sync <= 2'b00;
      m_cfg_epoch <= 8'd0;
      m_cfg_epoch_snap <= 8'd0;
      m_vsync[0] <= 8'h10; m_vsync[1] <= 8'h4e; m_vsync[2] <= 8'h07; m_vsync[3] <= 8'h25;
      m_vsync[4] <= 8'h07; m_vsync[5] <= 8'h07; m_vsync[6] <= 8'h90; m_vsync[7] <= 8'h65;
      m_cfg_dirty_sync <= 2'b00;
      m_v_disp <= 1'b0;
      m_col40_x <= 1'b0;
      m_v_pitch <= 8'd80;
      m_v_sad_lo <= 8'h00;
      m_v_sad_hi <= 8'h00;
      m_hdot <= 10'd0;
      m_vline <= 10'd0;
      m_r_wordidx <= 16'h0;
      m_r_raster <= 4'd0;
    end else begin
      // ---- CPU-side (not dot-gated): the cfg handshake ----
      m_cfg_data_d <= io_wr;
      if (m_cfg_data_d) m_cfg_dirty <= 1'b1;
      else if ((m_cfg_ack_sync[1] != m_cfg_ack_seen) && (m_cfg_epoch == m_cfg_epoch_snap))
        m_cfg_dirty <= 1'b0;
      if (io_wr) m_cfg_epoch <= m_cfg_epoch + 8'd1;
      m_cfg_ack_sync <= {m_cfg_ack_sync[0], m_cfg_ack};
      m_cfg_ack_seen <= m_cfg_ack_sync[1];

      // ---- CPU-side: the command/parameter capture ----
      if (io_wr) begin
        case (io_addr)
          8'h60: begin  // GDC1 parameter port
            if (m_sync_pending) begin
              m_slive[m_sync_cnt] <= io_din;
              if (m_sync_cnt == 3'd7) begin
                m_sync_pending <= 1'b0;
                m_sync_cnt <= 3'd0;
              end else m_sync_cnt <= m_sync_cnt + 3'd1;
            end else if (m_cmd_active) begin
              if ((m_cur_cmd == 8'h70) && (m_param_cnt[1:0] < 2'd2)) begin
                if (m_param_cnt[0] == 1'b0) m_pram0 <= io_din;
                else                        m_pram1 <= io_din;
              end
              if (m_param_cnt + 3'd1 == cmd_params(m_cur_cmd)) begin
                m_cmd_active <= 1'b0;
                m_param_cnt <= 3'd0;
                if (m_cur_cmd == 8'h47) m_pitch <= {io_din[7:1], 1'b0};
              end else m_param_cnt <= m_param_cnt + 3'd1;
            end
          end
          8'h62: begin  // GDC1 command port
            m_cur_cmd <= io_din;
            if (io_din == 8'h0E || io_din == 8'h0F) begin
              m_sync_pending <= 1'b1;
              m_sync_cnt <= 3'd0;
              m_cmd_active <= 1'b0;
              m_gdc_start <= io_din[0];
            end else if (io_din == 8'h0D || io_din == 8'h6B) begin
              m_gdc_start <= 1'b1;
              m_cmd_active <= 1'b0;
            end else if (io_din == 8'h0C || io_din == 8'h05) begin
              m_gdc_start <= 1'b0;
              m_cmd_active <= 1'b0;
            end else if (io_din == 8'h00) begin
              m_cmd_active <= 1'b0;
            end else if (cmd_params(io_din) != 4'd0) begin
              m_cmd_active <= 1'b1;
              m_param_cnt <= 3'd0;
            end else begin
              m_cmd_active <= 1'b0;
            end
          end
          8'h68: begin  // MODE FF1: bit = (dat>>1)&7, on = dat&1
            if (io_din[7:4] == 4'h0) begin
              if (io_din[0]) m_mode1 <= m_mode1 | (8'h01 << io_din[3:1]);
              else           m_mode1 <= m_mode1 & ~(8'h01 << io_din[3:1]);
            end
          end
          default: ;
        endcase
      end

      // ---- raster-side (dot-gated) ----
      if (pixel_ce) begin
        m_cfg_dirty_sync <= {m_cfg_dirty_sync[0], m_cfg_dirty};
        // The early copy of the walker's own address inputs, at the last walk slot...
        if (m_early_copy) begin
          m_v_sad_lo <= m_pram0;
          m_v_sad_hi <= m_pram1;
          m_v_pitch  <= m_pitch;
          m_col40_x  <= m_mode1[2];
        end
        // ...and the frame-boundary snapshot itself.
        if (m_snap_copy) begin
          m_v_disp  <= m_mode1[7] && m_gdc_start;
          m_col40_x <= m_mode1[2];
          m_v_pitch <= m_pitch;
          m_v_sad_lo <= m_pram0;
          m_v_sad_hi <= m_pram1;
          m_cfg_epoch_snap <= m_cfg_epoch;
          m_cfg_ack <= ~m_cfg_ack;
        end
        // The counters, and the unconditional sync_live -> v_sync frame-boundary copy.
        if (m_frame_end) begin
          m_hdot <= 10'd0;
          m_vline <= 10'd0;
          for (m_i = 0; m_i < 8; m_i = m_i + 1) m_vsync[m_i] <= m_slive[m_i];
        end else if (m_hdot == g_htotal - 1) begin
          m_hdot <= 10'd0;
          m_vline <= m_vline + 10'd1;
        end else m_hdot <= m_hdot + 10'd1;
        // The render captures at cell_done (the documented latches).
        if (m_cell_done) begin
          m_r_wordidx <= m_wordidx[15:0];
          m_r_raster  <= m_f_raster[3:0];
        end
      end
    end
  end

  // =====================================================================
  // THE CHECKER - every clk_sys cycle, one dot late in the cycle (#1 after
  // the negedge, so any same-edge stimulus has settled).
  // =====================================================================
  // m_col40_x above is written by the model's raster block with the same edge rules as
  // the DUT's v_col40 (the documented wk_cfg_snap early copy and the frame_end snapshot).
  integer errors = 0;
  integer n_checks = 0;
  integer cov_walker = 0, cov_lo = 0, cov_hi = 0, cov_at = 0, cov_default = 0;
  integer cov_wrapped = 0, cov_hi12 = 0, cov_col40 = 0, cov_snap = 0, cov_defer = 0;
  integer cov_frames = 0, cov_dispoff = 0;
  integer cov_odd_vtotal = 0, cov_early_active = 0;
  reg [31:0] cycle_no = 0;

  task automatic faila(input string what, input [31:0] got, input [31:0] want);
    begin
      if (got !== want) begin
        $display("FAIL %0s: got %08x want %08x @%0t cycle %0d (dut vline %0d hdot %0d)",
                 what, got, want, $time, cycle_no, dut.vline, dut.hdot);
        errors = errors + 1;
      end
    end
  endtask

  // Only the first few mismatches of each name print; the counters still fail the run.
  integer printed = 0;
  task automatic failq(input string what, input [31:0] got, input [31:0] want);
    begin
      if (got !== want) begin
        errors = errors + 1;
        if (printed < 20) begin
          printed = printed + 1;
          $display("FAIL %0s: got %08x want %08x @%0t cycle %0d (dut vline %0d hdot %0d)",
                   what, got, want, $time, cycle_no, dut.vline, dut.hdot);
        end
      end
    end
  endtask

  always @(negedge clk_sys) begin
    #1;
    cycle_no = cycle_no + 1;
    n_checks = n_checks + 1;
    compute_golden;

    // [geom-shared-bit-identity]: the shared geometry every consumer reads - the fetch
    // walker, pc9821_gdc2's wrapped display line through o_vtotal/o_vline, and the parity
    // fix's feed_odd/at_line_tick expression - is the documented field map of the
    // frame-boundary-sampled block AT EVERY CYCLE, and the outputs carry the same wires.
    failq("geom-shared-bit-identity HTOTAL", dut.HTOTAL, g_htotal);
    failq("geom-shared-bit-identity VTOTAL", dut.VTOTAL, g_vtotal);
    failq("geom-shared-bit-identity HACTIVE", dut.HACTIVE, g_hactive);
    failq("geom-shared-bit-identity VACTIVE", dut.VACTIVE, g_vactive);
    faila("geom-shared-bit-identity o_htotal", o_htotal, dut.HTOTAL);
    faila("geom-shared-bit-identity o_vtotal", o_vtotal, dut.VTOTAL);
    faila("geom-shared-bit-identity o_vline", o_vline, dut.vline);
    faila("geom-shared-bit-identity o_hdot", o_hdot, dut.hdot);

    // [linetick-dot-outside-active]: parity contract invariant (3) - the hdot == HTOTAL-1
    // line tick is never inside the mixer's active window. The second sub-check is a
    // belt-and-braces tripwire, trivially implied by the first (HTOTAL-1 >= HTOTAL-7 >
    // HTOTAL-8 >= HACTIVE); at_line_tick's identity with pc9821_system's
    // gvram_scan_line_tick rests on the shared crtc_o_htotal wire and is out of this
    // bench's scope.
    if (!(dut.HACTIVE <= dut.HTOTAL - 8))
      failq("linetick-dot-outside-active HACTIVE<=HTOTAL-8", dut.HACTIVE, dut.HTOTAL - 8);
    if ((dut.hdot == dut.HTOTAL - 1) && (dut.hdot < dut.HACTIVE))
      failq("linetick-dot-outside-active tick dot active", dut.hdot, dut.HACTIVE);

    // [fetch-arm-select] and [walker-arm-priority]: the arm select and the port value.
    if (dut.txt_on !== m_txt_on[0]) failq("fetch-arm-select txt_on", dut.txt_on, m_txt_on[0]);
    if (dut.fetch_lo !== m_f_lo[0]) failq("fetch-arm-select fetch_lo", dut.fetch_lo, m_f_lo[0]);
    if (dut.fetch_hi !== m_f_hi[0]) failq("fetch-arm-select fetch_hi", dut.fetch_hi, m_f_hi[0]);
    if (dut.fetch_at !== m_f_at[0]) failq("fetch-arm-select fetch_at", dut.fetch_at, m_f_at[0]);
    faila("walker-arm-priority tram_vid_addr", dut.tram_vid_addr, exp_addr);

    // [wordidx-consume]: the full word index at every dot that consumes it.
    if (m_f_lo || m_f_hi || m_f_at || m_cell_done)
      faila("wordidx-consume f_wordidx", dut.f_wordidx, m_wordidx[15:0]);

    // [capture-r-wordidx] / [capture-r-raster]: what reaches the render registers.
    faila("capture-r-wordidx r_wordidx", dut.r_wordidx, m_r_wordidx);
    faila("capture-r-raster r_raster", dut.r_raster, m_r_raster);

    // coverage, so a golden that computes 14'h0000 every cycle cannot pass
    if (wk_tr_read) cov_walker = cov_walker + 1;
    if (m_f_lo) cov_lo = cov_lo + 1;
    if (m_f_hi) cov_hi = cov_hi + 1;
    if (m_f_at) cov_at = cov_at + 1;
    if (!(wk_tr_read || m_f_lo || m_f_hi || m_f_at)) cov_default = cov_default + 1;
    if (m_wrapped_fetch) cov_wrapped = cov_wrapped + 1;
    if ((m_f_lo || m_f_hi || m_f_at) && m_wordidx[12]) cov_hi12 = cov_hi12 + 1;
    if (m_col40_x && (m_f_lo || m_f_hi || m_f_at)) cov_col40 = cov_col40 + 1;
    if (m_snap_copy) cov_snap = cov_snap + 1;
    if (m_frame_end) cov_frames = cov_frames + 1;
    // the two stimulus classes P2-1 needs: odd frame lengths (VTOTAL[0],
    // the parity expression's input) and an early copy whose new pitch/sad surface on
    // ACTIVE consuming dots (the walk slot inside the display window).
    if (m_frame_end && g_vtotal[0]) cov_odd_vtotal = cov_odd_vtotal + 1;
    if (m_early_copy && (m_wk_slot < g_vactive)) cov_early_active = cov_early_active + 1;
    if (!m_v_disp && (m_hdot < g_hactive) && (m_vline < g_vactive)) cov_dispoff = cov_dispoff + 1;
    if (io_wr && (m_hdot >= g_htotal - 2)) cov_defer = cov_defer + 1;
  end

  // =====================================================================
  // STIMULUS
  // =====================================================================
  task automatic write_io(input [7:0] portnum, input [7:0] data);
    begin
      @(negedge clk_sys);
      io_addr = portnum;
      io_din = data;
      io_wr = 1'b1;
      @(negedge clk_sys);
      io_wr = 1'b0;
    end
  endtask

  task automatic write_pitch(input [7:0] p);
    begin
      write_io(8'h62, 8'h47);
      write_io(8'h60, p);
    end
  endtask

  task automatic write_pram(input [15:0] sad);
    begin
      write_io(8'h62, 8'h70);
      write_io(8'h60, sad[7:0]);
      write_io(8'h60, sad[15:8]);
      write_io(8'h60, 8'h00);
      write_io(8'h60, 8'h00);
    end
  endtask

  // The guest's SYNC transaction: the command byte on 0x62, then the block's eight bytes
  // on 0x60 in arrival order (the documented capture).
  reg [7:0] sb[0:7];
  integer si;
  task automatic write_sync;
    begin
      write_io(8'h62, 8'h0F);   // SYNC on (also the gdc_start the display needs)
      for (si = 0; si < 8; si = si + 1) write_io(8'h60, sb[si]);
    end
  endtask

  task automatic wait_dot(input [9:0] line, input [9:0] dot);
    begin
      wait (dut.vline == line && dut.hdot == dot);
    end
  endtask

  task automatic run_clks(input integer n);
    begin
      repeat (n) @(negedge clk_sys);
    end
  endtask

  // ---- pixel_ce patterns and the walker's borrowed port ----
  reg [2:0] ce_mode = 3'd0;   // 0: every clk  1: 1-in-2  2: 1-in-4  3: irregular + bursts
  reg [1:0] wk_mode = 2'd0;   // 0: silent  1: sparse random  2: heavy random (collisions)
  reg [15:0] lfsr = 16'hACE1;
  always @(negedge clk_sys) begin
    lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    case (ce_mode)
      3'd0: pixel_ce <= 1'b1;
      3'd1: pixel_ce <= lfsr[0];
      3'd2: pixel_ce <= (lfsr[1:0] == 2'b00);
      default: pixel_ce <= (lfsr[2:0] == 3'b000) || (lfsr[2:0] == 3'b101);
    endcase
    case (wk_mode)
      2'd0: wk_tr_read <= 1'b0;
      2'd1: wk_tr_read <= (lfsr[3:0] == 4'h0);
      default: wk_tr_read <= lfsr[3] | lfsr[7] | ((dut.hdot == 10'd0) ? 1'b1 : 1'b0);
    endcase
    if (wk_mode != 2'd0) wk_tr_addr <= {lfsr[13:0]};
  end

  task automatic expect_gt(input integer got, input integer want, input string what);
    begin
      if (got <= want) begin
        $display("FAIL coverage %0s: %0d, want > %0d", what, got, want);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    // ---- the DEFAULT block (defsyncm24), then the 550-line block of
    // tb_pc9821_gdc_sync_raster case 3 (lf 480, vs 10, vfp 20, vbp 40 -> 848x550).
    sb[0] = 8'h10; sb[1] = 8'h4e; sb[2] = 8'h07; sb[3] = 8'h25;
    sb[4] = 8'h07; sb[5] = 8'h07; sb[6] = 8'h90; sb[7] = 8'h65;

    repeat (8) @(negedge clk_sys);
    rst_n = 1'b1;
    run_clks(64);

    // BCTRL on (the display start) and the default geometry's registers.
    write_io(8'h62, 8'h0D);
    write_pitch(8'd80);
    write_pram(16'h0000);

    // ---- phase A: the default frame, pixel_ce every clk, sparse walker ----
    wk_mode = 2'd1;
    run_clks(800_000);

    // ---- phase B: mid-frame writes and the frame-boundary snapshot windows ----
    wait_dot(10'd100, 10'd100);
    write_pitch(8'd95);            // the odd bit is dropped by the documented capture
    wait_dot(10'd200, 10'd200);
    write_pram(16'h1234);          // high sad bits: the LOW12 mask of the fetch arms
    wait_dot(10'd438, 10'd800);    // vblank, AFTER the walk slot's early copy (vline 431)
                                   // has passed: this write exercises the documented MISS
                                   // path - only the frame_end snapshot sees it
    write_pitch(8'd88);
    wait_dot(10'd439, 10'd845);    // ON the frame_end edge's neighbourhood (the defer window)
    write_pram(16'h0F00);
    write_pitch(8'd80);
    wait_dot(10'd439, 10'd846);
    write_pram(16'h0100);          // two back-to-back writes across the snapshot edge
    run_clks(800_000);

    // ---- phase C: irregular pixel_ce gaps, a blanked display and back ----
    ce_mode = 3'd2;
    run_clks(1_500_000);
    write_io(8'h68, 8'h0E);        // MODE FF1 DISP off
    run_clks(300_000);
    write_io(8'h68, 8'h0F);        // ...and on
    run_clks(1_200_000);

    // ---- phase D: a frame-boundary SYNC swap to the 550-line block ----
    ce_mode = 3'd0;
    wait_dot(10'd50, 10'd50);
    sb[0] = 8'h10; sb[1] = 8'h4e; sb[2] = 8'h47; sb[3] = 8'h25;
    sb[4] = 8'h07; sb[5] = 8'h14; sb[6] = 8'he0; sb[7] = 8'hA1;
    write_sync;
    run_clks(1_100_000);           // two 848x550 frames plus change

    // ---- phase E: 40-column cells mid-run, heavy walker collisions ----
    ce_mode = 3'd1;
    wk_mode = 2'd2;
    wait_dot(10'd100, 10'd100);
    write_io(8'h68, 8'h05);        // MODE FF1 bit 2 on: 40-column
    wait_dot(10'd300, 10'd300);
    write_pitch(8'd80);
    wait_dot(10'd540, 10'd10);     // inside the 550-line frame's vblank (its lines run
                                   // 0..549), before its end
    write_pram(16'h0FF0);
    run_clks(2_400_000);
    wait_dot(10'd100, 10'd100);
    write_io(8'h68, 8'h04);        // back to 80-column
    run_clks(1_200_000);

    // ---- phase F: back to the default block at a frame boundary ----
    ce_mode = 3'd3;
    wait_dot(10'd50, 10'd50);
    sb[0] = 8'h10; sb[1] = 8'h4e; sb[2] = 8'h07; sb[3] = 8'h25;
    sb[4] = 8'h07; sb[5] = 8'h07; sb[6] = 8'h90; sb[7] = 8'h65;
    write_sync;
    run_clks(1_500_000);

    // ---- phase G: odd-VTOTAL and VACTIVE = VTOTAL-1 blocks (P2-1) ----
    // G1: defsyncm24 with vbp 26 (lf 400, vs 8, vfp 7, vbp 26 -> y 441): the frame
    // length is ODD, so VTOTAL[0] and the vline+2 >= VTOTAL wrap run with the parity
    // expression's own inputs. The equivalence proof is parity-independent; this closes
    // the stimulus gap (both earlier blocks were even: 440 and 550).
    ce_mode = 3'd1;
    wait_dot(10'd50, 10'd50);
    sb[0] = 8'h10; sb[1] = 8'h4e; sb[2] = 8'h07; sb[3] = 8'h25;
    sb[4] = 8'h07; sb[5] = 8'h07; sb[6] = 8'h90; sb[7] = 8'h69;
    write_sync;
    wait_dot(10'd200, 10'd200);
    write_pram(16'h0300);          // dirty the cfg so the odd block's snapshot fires
    run_clks(1_600_000);           // two 848x441 frames

    // G2: lf ~= y-1 (lf 440, vs 1, vfp 0, vbp 0 -> y 441, VACTIVE 440 = VTOTAL-1):
    // the walk slot lands at vline 431 and its early copy surfaces on the ACTIVE line
    // 432's consuming dots, so a mid-frame pitch/sad change reaches active fetches
    // through the wk_cfg_snap path (every earlier block surfaced it in vblank).
    wait_dot(10'd50, 10'd50);
    sb[0] = 8'h10; sb[1] = 8'h4e; sb[2] = 8'h27; sb[3] = 8'h24;
    sb[4] = 8'h07; sb[5] = 8'h00; sb[6] = 8'hB8; sb[7] = 8'h01;
    write_sync;
    run_clks(800_000);           // past the frame end that INSTALLS the G2 block - a
                                 // write before it would land in the old block's frame
    wait_dot(10'd430, 10'd200);  // just BEFORE the walk slot's early copy (vline 431)
    write_pitch(8'd72);
    write_pram(16'h0C00);
    run_clks(800_000);           // a full 848x441 frame with VACTIVE = VTOTAL-1
    wait_dot(10'd430, 10'd200);  // a second early-copy window, on a later frame
    write_pram(16'h0600);
    run_clks(800_000);

    // ==== coverage: every arm, both column sizes, the wrap fetch, the masked bits,
    // the snapshot (with the defer window) and a blanked display must all have happened
    expect_gt(cov_walker, 1000, "walker arm cycles");
    expect_gt(cov_lo, 50_000, "fetch-lo arm cycles");
    expect_gt(cov_hi, 50_000, "fetch-hi arm cycles");
    expect_gt(cov_at, 50_000, "fetch-at arm cycles");
    expect_gt(cov_default, 1000, "default-arm cycles");
    expect_gt(cov_wrapped, 8, "wrap fetches (next frame's row 0 col 0)");
    expect_gt(cov_hi12, 1000, "fetches with wordidx[12] set (the LOW12 mask)");
    expect_gt(cov_col40, 50_000, "40-column fetch cycles");
    expect_gt(cov_snap, 4, "frame-boundary snapshots");
    expect_gt(cov_frames, 20, "frames");
    expect_gt(cov_dispoff, 1000, "active dots with the display blanked");
    expect_gt(cov_defer, 1, "writes in the frame_end defer window");
    expect_gt(cov_odd_vtotal, 2, "frame ends with odd VTOTAL");
    expect_gt(cov_early_active, 1, "wk_cfg_snap early copies surfacing on active lines");

    $display("tram-addr-equiv: %0d cycles checked", n_checks);
    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_TRAM_ADDR_EQUIV: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_TRAM_ADDR_EQUIV: FAIL (%0d errors)", errors);
    end
  end

  initial begin
    // Six phases, ~10M clk_sys total at the longest; a literal bound for the structure
    // checkers (`repeat ( <number> ) @(posedge ...`).
    repeat (40_000_000) @(posedge clk_sys);
    $fatal(1, "TB_PC9821_TRAM_ADDR_EQUIV: TIMEOUT");
  end
endmodule
