`default_nettype none

// The reference does its arithmetic in `integer` (32-bit) exactly as the C does, so Verilator's
// width notes about NP2kai's 16-bit registers are expected here. tests/ is out of check_lint.py's
// scope (a bench is not shipped RTL); the waivers keep the bench build log readable.
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

// The op/op8/op16/op32/seed entry tasks carry the `no_inline_task` Verilator
// metacomment so Verilator compiles each of them ONCE instead of inlining a copy at
// every tb call site. Without it tb_pc9821_egc_conformance emits ~3.4M lines /
// 290 MB of C++ and takes ~14 minutes to compile; with it the golden is a handful
// of shared functions (~23 MB, ~30 s). The module-level regs those tasks touch are
// reached through the same vlSelf pointer the inlined form used, and tools/bench.py
// waives IMPURE for this reason (the differential suite still compares every case
// byte-for-byte).

// pc9821_egc_ref -- the GOLDEN EGC, a behavioural reference for the differential
// conformance bench (tb_pc9821_egc_conformance.sv). It is a direct transcription of
// NP2kai's emulation, function for function:
//
//   mem/memegc.c  egcshift, shiftinput_{byte,incw,decw}, egcsftb_*_sub, egcsftb_*0,
//                 egcsftw_*0, egc_opeb, egc_opew, the opefn[] ROPs (ope_xx/ope_np/
//                 ope_nd/ope_00/ope_0f/ope_c0/ope_f0/ope_fc/ope_ff), egc_readbyte,
//                 egc_writebyte, egc_readword, egc_writeword, memegc_{rd,wr}{8,16,32}
//   io/egc.c      the register handlers (0x4A0-0x4AE), the maskword[16][4] fg/bg
//                 expansion, egc_reset
//
// No timing: one op() call is atomic and runs in zero time. The plane store is
// indexed [plane][page][byte offset in the 32 KiB window], which is NP2kai's
// mem[ad + VRAM_x] with ad = page_bit | (addr & 0x7FFF) and the four VRAM bases
// dropped; the byte window address is folded to the offset by LOW15() on a write
// (memegc.c egc_writeword/byte) while a read keeps the addressed plane.
//
// The two NP2kai sources are the ONLY authority here; where this file and the RTL
// disagree the bench names both.

module pc9821_egc_ref;
  // ---- the plane store ----
  reg [7:0] mem [0:3][0:1][0:32767];

  // ---- register file (io/egc.c egc_w16) ----
  reg [15:0] r_access, r_fgbg, r_ope, r_fg, r_mask, r_bg, r_sft, r_leng;
  reg [15:0] fgc [0:3];   // the fg colour quad, maskword[fg & 15]
  reg [15:0] bgc [0:3];   // the bg colour quad

  // ---- shifter state (memegc.c) ----
  // ebuf/inptr/outptr are egc.ebuf and egc.inptr/egc.outptr. NP2kai starts the ascending
  // walk at ebuf and the descending walk at ebuf + 4096/8 + 3; the two regions are kept
  // disjoint and byte-identical by starting them at 0 and BUF_TOP here, the same layout.
  localparam integer BUF_TOP = 4096;
  reg [7:0] ebuf [0:8191];
  integer inptr, outptr;
  integer remain, stack;
  integer srcbit, dstbit, func, s8l, s8r;
  reg [15:0] srcmask;              // egc.srcmask
  reg [15:0] lastvram [0:3];       // egc.lastvram, per-plane 16-bit word
  reg [15:0] patreg   [0:3];       // egc.patreg
  reg [15:0] sft_q    [0:3];       // egc_src, the shifter's output quad
  reg [15:0] dqw      [0:3];       // egc_data, the path's result quad
  reg [15:0] mask2;                // egc.mask2
  reg [15:0] rop_res  [0:3];       // the opefn[256] result quad
  reg [15:0] pat_q    [0:3];       // the ROP's pattern term
  reg [15:0] col_q    [0:3];       // the maskword[16] colour expansion scratch

  // ---- the mask tables, memegc.c:20-54 ----
  reg [7:0] bm_u0 [0:63];
  reg [7:0] bm_u1 [0:7];
  reg [7:0] bm_d0 [0:63];
  reg [7:0] bm_d1 [0:7];
  integer mi;
  initial begin
    for (mi = 0; mi < 64; mi = mi + 1) begin bm_u0[mi] = 8'h00; bm_d0[mi] = 8'h00; end
    for (mi = 0; mi < 8; mi = mi + 1) begin bm_u1[mi] = 8'h00; bm_d1[mi] = 8'h00; end
    bm_u0[ 0]=8'h80; bm_u0[ 1]=8'h40; bm_u0[ 2]=8'h20; bm_u0[ 3]=8'h10;
    bm_u0[ 4]=8'h08; bm_u0[ 5]=8'h04; bm_u0[ 6]=8'h02; bm_u0[ 7]=8'h01;
    bm_u0[ 8]=8'hc0; bm_u0[ 9]=8'h60; bm_u0[10]=8'h30; bm_u0[11]=8'h18;
    bm_u0[12]=8'h0c; bm_u0[13]=8'h06; bm_u0[14]=8'h03; bm_u0[15]=8'h01;
    bm_u0[16]=8'he0; bm_u0[17]=8'h70; bm_u0[18]=8'h38; bm_u0[19]=8'h1c;
    bm_u0[20]=8'h0e; bm_u0[21]=8'h07; bm_u0[22]=8'h03; bm_u0[23]=8'h01;
    bm_u0[24]=8'hf0; bm_u0[25]=8'h78; bm_u0[26]=8'h3c; bm_u0[27]=8'h1e;
    bm_u0[28]=8'h0f; bm_u0[29]=8'h07; bm_u0[30]=8'h03; bm_u0[31]=8'h01;
    bm_u0[32]=8'hf8; bm_u0[33]=8'h7c; bm_u0[34]=8'h3e; bm_u0[35]=8'h1f;
    bm_u0[36]=8'h0f; bm_u0[37]=8'h07; bm_u0[38]=8'h03; bm_u0[39]=8'h01;
    bm_u0[40]=8'hfc; bm_u0[41]=8'h7e; bm_u0[42]=8'h3f; bm_u0[43]=8'h1f;
    bm_u0[44]=8'h0f; bm_u0[45]=8'h07; bm_u0[46]=8'h03; bm_u0[47]=8'h01;
    bm_u0[48]=8'hfe; bm_u0[49]=8'h7f; bm_u0[50]=8'h3f; bm_u0[51]=8'h1f;
    bm_u0[52]=8'h0f; bm_u0[53]=8'h07; bm_u0[54]=8'h03; bm_u0[55]=8'h01;
    bm_u0[56]=8'hff; bm_u0[57]=8'h7f; bm_u0[58]=8'h3f; bm_u0[59]=8'h1f;
    bm_u0[60]=8'h0f; bm_u0[61]=8'h07; bm_u0[62]=8'h03; bm_u0[63]=8'h01;
    bm_u1[0]=8'h80; bm_u1[1]=8'hc0; bm_u1[2]=8'he0; bm_u1[3]=8'hf0;
    bm_u1[4]=8'hf8; bm_u1[5]=8'hfc; bm_u1[6]=8'hfe; bm_u1[7]=8'hff;
    bm_d0[ 0]=8'h01; bm_d0[ 1]=8'h02; bm_d0[ 2]=8'h04; bm_d0[ 3]=8'h08;
    bm_d0[ 4]=8'h10; bm_d0[ 5]=8'h20; bm_d0[ 6]=8'h40; bm_d0[ 7]=8'h80;
    bm_d0[ 8]=8'h03; bm_d0[ 9]=8'h06; bm_d0[10]=8'h0c; bm_d0[11]=8'h18;
    bm_d0[12]=8'h30; bm_d0[13]=8'h60; bm_d0[14]=8'hc0; bm_d0[15]=8'h80;
    bm_d0[16]=8'h07; bm_d0[17]=8'h0e; bm_d0[18]=8'h1c; bm_d0[19]=8'h38;
    bm_d0[20]=8'h70; bm_d0[21]=8'he0; bm_d0[22]=8'hc0; bm_d0[23]=8'h80;
    bm_d0[24]=8'h0f; bm_d0[25]=8'h1e; bm_d0[26]=8'h3c; bm_d0[27]=8'h78;
    bm_d0[28]=8'hf0; bm_d0[29]=8'he0; bm_d0[30]=8'hc0; bm_d0[31]=8'h80;
    bm_d0[32]=8'h1f; bm_d0[33]=8'h3e; bm_d0[34]=8'h7c; bm_d0[35]=8'hf8;
    bm_d0[36]=8'hf0; bm_d0[37]=8'he0; bm_d0[38]=8'hc0; bm_d0[39]=8'h80;
    bm_d0[40]=8'h3f; bm_d0[41]=8'h7e; bm_d0[42]=8'hfc; bm_d0[43]=8'hf8;
    bm_d0[44]=8'hf0; bm_d0[45]=8'he0; bm_d0[46]=8'hc0; bm_d0[47]=8'h80;
    bm_d0[48]=8'h7f; bm_d0[49]=8'hfe; bm_d0[50]=8'hfc; bm_d0[51]=8'hf8;
    bm_d0[52]=8'hf0; bm_d0[53]=8'he0; bm_d0[54]=8'hc0; bm_d0[55]=8'h80;
    bm_d0[56]=8'hff; bm_d0[57]=8'hfe; bm_d0[58]=8'hfc; bm_d0[59]=8'hf8;
    bm_d0[60]=8'hf0; bm_d0[61]=8'he0; bm_d0[62]=8'hc0; bm_d0[63]=8'h80;
    bm_d1[0]=8'h01; bm_d1[1]=8'h03; bm_d1[2]=8'h07; bm_d1[3]=8'h0f;
    bm_d1[4]=8'h1f; bm_d1[5]=8'h3f; bm_d1[6]=8'h7f; bm_d1[7]=8'hff;
  end

  // ================================================================
  // Register file (io/egc.c)
  // ================================================================
  task automatic col_planes(input [15:0] colour);
    begin
      col_q[0] = ((colour & 16'h0001) != 0) ? 16'hFFFF : 16'h0000;
      col_q[1] = ((colour & 16'h0002) != 0) ? 16'hFFFF : 16'h0000;
      col_q[2] = ((colour & 16'h0004) != 0) ? 16'hFFFF : 16'h0000;
      col_q[3] = ((colour & 16'h0008) != 0) ? 16'hFFFF : 16'h0000;
    end
  endtask

  task automatic rst();
    integer p;
    begin
      for (p = 0; p < 4; p = p + 1) begin
        fgc[p] = 16'h0000; bgc[p] = 16'h0000; patreg[p] = 16'h0000;
        lastvram[p] = 16'h0000; sft_q[p] = 16'h0000; dqw[p] = 16'h0000;
        rop_res[p] = 16'h0000; pat_q[p] = 16'h0000;
      end
      for (p = 0; p < 8192; p = p + 1) ebuf[p] = 8'h00;
      r_access = 16'hFFF0; r_fgbg = 16'h00FF; r_ope = 16'h0000; r_fg = 16'h0000;
      r_mask = 16'hFFFF; r_bg = 16'h0000; r_sft = 16'h0000; r_leng = 16'h000F;
      egcshift();
      srcmask = 16'hFFFF;
    end
  endtask

  task automatic set_access(input [15:0] v);   begin r_access = v; end endtask
  task automatic set_fgbg(input [15:0] v);     begin r_fgbg = v; end endtask
  task automatic set_ope(input [15:0] v);      begin r_ope = v; end endtask
  task automatic set_fg(input [15:0] v);
    begin r_fg = v; col_planes(v); fgc[0] = col_q[0]; fgc[1] = col_q[1];
          fgc[2] = col_q[2]; fgc[3] = col_q[3]; end
  endtask
  task automatic set_bg(input [15:0] v);
    begin r_bg = v; col_planes(v); bgc[0] = col_q[0]; bgc[1] = col_q[1];
          bgc[2] = col_q[2]; bgc[3] = col_q[3]; end
  endtask
  // io/egc.c:0x08/0x0a gate the mask/colour writes on the colour-quad select.
  task automatic set_mask(input [15:0] v);
    begin if ((r_fgbg & 16'h6000) == 16'h0000) r_mask = v; end
  endtask
  // 0x4AC/0x4AE: egcshift() then srcmask = 0xffff (io/egc.c:91-113).
  task automatic set_sft(input [15:0] v);
    begin r_sft = v; egcshift(); srcmask = 16'hFFFF; end
  endtask
  task automatic set_leng(input [15:0] v);
    begin r_leng = v; egcshift(); srcmask = 16'hFFFF; end
  endtask

  // ================================================================
  // The shifter (memegc.c:51-107)
  // ================================================================
  task automatic egcshift();
    integer t8, d8;
    begin
      remain = (r_leng & 16'h0FFF) + 1;
      func = (r_sft >> 12) & 1;
      if (func == 0) begin inptr = 0; outptr = 0; end
      else           begin inptr = BUF_TOP; outptr = BUF_TOP; end
      srcbit = r_sft & 16'h000F;
      dstbit = (r_sft >> 4) & 16'h000F;
      t8 = srcbit & 7;
      d8 = dstbit & 7;
      if (t8 < d8) begin
        func = func + 2; s8r = d8 - t8; s8l = 8 - s8r;
      end else if (t8 > d8) begin
        func = func + 4; s8l = t8 - d8; s8r = 8 - s8l;
      end
      stack = 0;
    end
  endtask

  // ---- the six single-byte produce steps ----
  task automatic sftb_upn_sub(input integer ext);      // dir 0, src8 == dst8
    begin
      if (dstbit >= 8) begin
        dstbit = dstbit - 8;
        srcmask[8*ext +: 8] = 8'h00;
      end else begin
        if (dstbit != 0) begin
          if ((dstbit + remain) >= 8) begin
            srcmask[8*ext +: 8] = bm_u0[dstbit + 56];
            remain = remain - (8 - dstbit);
          end else begin
            srcmask[8*ext +: 8] = bm_u0[dstbit + (remain - 1) * 8];
            remain = 0;
          end
          dstbit = 0;
        end else begin
          if (remain >= 8) remain = remain - 8;
          else begin srcmask[8*ext +: 8] = bm_u1[remain - 1]; remain = 0; end
        end
        sft_q[0][8*ext +: 8] = ebuf[outptr + 0];
        sft_q[1][8*ext +: 8] = ebuf[outptr + 4];
        sft_q[2][8*ext +: 8] = ebuf[outptr + 8];
        sft_q[3][8*ext +: 8] = ebuf[outptr + 12];
        outptr = outptr + 1;
      end
    end
  endtask

  task automatic sftb_dnn_sub(input integer ext);      // dir 1, src8 == dst8
    begin
      if (dstbit >= 8) begin
        dstbit = dstbit - 8;
        srcmask[8*ext +: 8] = 8'h00;
      end else begin
        if (dstbit != 0) begin
          if ((dstbit + remain) >= 8) begin
            srcmask[8*ext +: 8] = bm_d0[dstbit + 56];
            remain = remain - (8 - dstbit);
          end else begin
            srcmask[8*ext +: 8] = bm_d0[dstbit + (remain - 1) * 8];
            remain = 0;
          end
          dstbit = 0;
        end else begin
          if (remain >= 8) remain = remain - 8;
          else begin srcmask[8*ext +: 8] = bm_d1[remain - 1]; remain = 0; end
        end
        sft_q[0][8*ext +: 8] = ebuf[outptr + 0];
        sft_q[1][8*ext +: 8] = ebuf[outptr + 4];
        sft_q[2][8*ext +: 8] = ebuf[outptr + 8];
        sft_q[3][8*ext +: 8] = ebuf[outptr + 12];
        outptr = outptr - 1;
      end
    end
  endtask

  task automatic sftb_upr_sub(input integer ext);      // dir 0, src8 < dst8
    begin
      if (dstbit >= 8) begin
        dstbit = dstbit - 8;
        srcmask[8*ext +: 8] = 8'h00;
      end else begin
        if (dstbit != 0) begin
          if ((dstbit + remain) >= 8) begin
            srcmask[8*ext +: 8] = bm_u0[dstbit + 56];
            remain = remain - (8 - dstbit);
          end else begin
            srcmask[8*ext +: 8] = bm_u0[dstbit + (remain - 1) * 8];
            remain = 0;
          end
          dstbit = 0;
          sft_q[0][8*ext +: 8] = ebuf[outptr + 0]  >> s8r;
          sft_q[1][8*ext +: 8] = ebuf[outptr + 4]  >> s8r;
          sft_q[2][8*ext +: 8] = ebuf[outptr + 8]  >> s8r;
          sft_q[3][8*ext +: 8] = ebuf[outptr + 12] >> s8r;
        end else begin
          if (remain >= 8) remain = remain - 8;
          else begin srcmask[8*ext +: 8] = bm_u1[remain - 1]; remain = 0; end
          sft_q[0][8*ext +: 8] = (ebuf[outptr + 0] << s8l) | (ebuf[outptr + 1] >> s8r);
          sft_q[1][8*ext +: 8] = (ebuf[outptr + 4] << s8l) | (ebuf[outptr + 5] >> s8r);
          sft_q[2][8*ext +: 8] = (ebuf[outptr + 8] << s8l) | (ebuf[outptr + 9] >> s8r);
          sft_q[3][8*ext +: 8] = (ebuf[outptr + 12] << s8l) | (ebuf[outptr + 13] >> s8r);
          outptr = outptr + 1;
        end
      end
    end
  endtask

  task automatic sftb_dnr_sub(input integer ext);      // dir 1, src8 < dst8
    begin
      if (dstbit >= 8) begin
        dstbit = dstbit - 8;
        srcmask[8*ext +: 8] = 8'h00;
      end else begin
        if (dstbit != 0) begin
          if ((dstbit + remain) >= 8) begin
            srcmask[8*ext +: 8] = bm_d0[dstbit + 56];
            remain = remain - (8 - dstbit);
          end else begin
            srcmask[8*ext +: 8] = bm_d0[dstbit + (remain - 1) * 8];
            remain = 0;
          end
          dstbit = 0;
          sft_q[0][8*ext +: 8] = ebuf[outptr + 0]  << s8r;
          sft_q[1][8*ext +: 8] = ebuf[outptr + 4]  << s8r;
          sft_q[2][8*ext +: 8] = ebuf[outptr + 8]  << s8r;
          sft_q[3][8*ext +: 8] = ebuf[outptr + 12] << s8r;
        end else begin
          if (remain >= 8) remain = remain - 8;
          else begin srcmask[8*ext +: 8] = bm_d1[remain - 1]; remain = 0; end
          outptr = outptr - 1;
          sft_q[0][8*ext +: 8] = (ebuf[outptr + 1] >> s8l) | (ebuf[outptr + 0] << s8r);
          sft_q[1][8*ext +: 8] = (ebuf[outptr + 5] >> s8l) | (ebuf[outptr + 4] << s8r);
          sft_q[2][8*ext +: 8] = (ebuf[outptr + 9] >> s8l) | (ebuf[outptr + 8] << s8r);
          sft_q[3][8*ext +: 8] = (ebuf[outptr + 13] >> s8l) | (ebuf[outptr + 12] << s8r);
        end
      end
    end
  endtask

  task automatic sftb_upl_sub(input integer ext);      // dir 0, src8 > dst8
    begin
      if (dstbit >= 8) begin
        dstbit = dstbit - 8;
        srcmask[8*ext +: 8] = 8'h00;
      end else begin
        if (dstbit != 0) begin
          if ((dstbit + remain) >= 8) begin
            srcmask[8*ext +: 8] = bm_u0[dstbit + 56];
            remain = remain - (8 - dstbit);
          end else begin
            srcmask[8*ext +: 8] = bm_u0[dstbit + (remain - 1) * 8];
            remain = 0;
          end
          dstbit = 0;
        end else begin
          if (remain >= 8) remain = remain - 8;
          else begin srcmask[8*ext +: 8] = bm_u1[remain - 1]; remain = 0; end
        end
        sft_q[0][8*ext +: 8] = (ebuf[outptr + 0]  << s8l) | (ebuf[outptr + 1]  >> s8r);
        sft_q[1][8*ext +: 8] = (ebuf[outptr + 4]  << s8l) | (ebuf[outptr + 5]  >> s8r);
        sft_q[2][8*ext +: 8] = (ebuf[outptr + 8]  << s8l) | (ebuf[outptr + 9]  >> s8r);
        sft_q[3][8*ext +: 8] = (ebuf[outptr + 12] << s8l) | (ebuf[outptr + 13] >> s8r);
        outptr = outptr + 1;
      end
    end
  endtask

  task automatic sftb_dnl_sub(input integer ext);      // dir 1, src8 > dst8
    begin
      if (dstbit >= 8) begin
        dstbit = dstbit - 8;
        srcmask[8*ext +: 8] = 8'h00;
      end else begin
        if (dstbit != 0) begin
          if ((dstbit + remain) >= 8) begin
            srcmask[8*ext +: 8] = bm_d0[dstbit + 56];
            remain = remain - (8 - dstbit);
          end else begin
            srcmask[8*ext +: 8] = bm_d0[dstbit + (remain - 1) * 8];
            remain = 0;
          end
          dstbit = 0;
        end else begin
          if (remain >= 8) remain = remain - 8;
          else begin srcmask[8*ext +: 8] = bm_d1[remain - 1]; remain = 0; end
        end
        outptr = outptr - 1;
        sft_q[0][8*ext +: 8] = (ebuf[outptr + 1]  >> s8l) | (ebuf[outptr + 0]  << s8r);
        sft_q[1][8*ext +: 8] = (ebuf[outptr + 5]  >> s8l) | (ebuf[outptr + 4]  << s8r);
        sft_q[2][8*ext +: 8] = (ebuf[outptr + 9]  >> s8l) | (ebuf[outptr + 8]  << s8r);
        sft_q[3][8*ext +: 8] = (ebuf[outptr + 13] >> s8l) | (ebuf[outptr + 12] << s8r);
      end
    end
  endtask

  task automatic sftb_call(input integer ext);
    begin
      case (func)
        0: sftb_upn_sub(ext);
        1: sftb_dnn_sub(ext);
        2: sftb_upr_sub(ext);
        3: sftb_dnr_sub(ext);
        4: sftb_upl_sub(ext);
        default: sftb_dnl_sub(ext);
      endcase
    end
  endtask

  // NP2kai's egcsftb_*0 wrapper (mem/memegc.c:372-570), which shiftinput_byte calls in
  // place of the raw _sub: the byte produce's stack gate, its stack spend and the
  // bit-length re-arm. The gate's `(UINT)(8 - egc.dstbit)` wraps negative for
  // dstbit 9..15 (a faithful NP2kai quirk), so a produce there is
  // gated forever and only dstbit == 8 reaches the _sub's early return.
  task automatic sftb0(input integer ext);
    begin
      if ((dstbit > 8) || (stack < (8 - dstbit))) begin
        srcmask[8*ext +: 8] = 8'h00;
      end else begin
        stack = stack - (8 - dstbit);
        sftb_call(ext);
        if (remain == 0) egcshift();
      end
    end
  endtask

  // ---- the six per-unit word steps (L then H, or H then L) ----
  task automatic sftw_upn0();
    begin
      if (stack < (16 - dstbit)) begin srcmask = 16'h0000; end
      else begin
        stack = stack - (16 - dstbit);
        sftb_upn_sub(0);
        if (remain == 0) begin srcmask[15:8] = 8'h00; egcshift(); end
        else begin
          sftb_upn_sub(1);
          if (remain == 0) egcshift();
        end
      end
    end
  endtask

  task automatic sftw_dnn0();
    begin
      if (stack < (16 - dstbit)) begin srcmask = 16'h0000; end
      else begin
        stack = stack - (16 - dstbit);
        sftb_dnn_sub(1);
        if (remain == 0) begin srcmask[7:0] = 8'h00; egcshift(); end
        else begin
          sftb_dnn_sub(0);
          if (remain == 0) egcshift();
        end
      end
    end
  endtask

  task automatic sftw_upr0();
    begin
      if (stack < (16 - dstbit)) begin srcmask = 16'h0000; end
      else begin
        stack = stack - (16 - dstbit);
        sftb_upr_sub(0);
        if (remain == 0) begin srcmask[15:8] = 8'h00; egcshift(); end
        else begin
          sftb_upr_sub(1);
          if (remain == 0) egcshift();
        end
      end
    end
  endtask

  task automatic sftw_dnr0();
    begin
      if (stack < (16 - dstbit)) begin srcmask = 16'h0000; end
      else begin
        stack = stack - (16 - dstbit);
        sftb_dnr_sub(1);
        if (remain == 0) begin srcmask[7:0] = 8'h00; egcshift(); end
        else begin
          sftb_dnr_sub(0);
          if (remain == 0) egcshift();
        end
      end
    end
  endtask

  task automatic sftw_upl0();
    begin
      if (stack < (16 - dstbit)) begin srcmask = 16'h0000; end
      else begin
        stack = stack - (16 - dstbit);
        sftb_upl_sub(0);
        if (remain == 0) begin srcmask[15:8] = 8'h00; egcshift(); end
        else begin
          sftb_upl_sub(1);
          if (remain == 0) egcshift();
        end
      end
    end
  endtask

  task automatic sftw_dnl0();
    begin
      if (stack < (16 - dstbit)) begin srcmask = 16'h0000; end
      else begin
        stack = stack - (16 - dstbit);
        sftb_dnl_sub(1);
        if (remain == 0) begin srcmask[7:0] = 8'h00; egcshift(); end
        else begin
          sftb_dnl_sub(0);
          if (remain == 0) egcshift();
        end
      end
    end
  endtask

  task automatic sftw_call();
    begin
      case (func)
        0: sftw_upn0();
        1: sftw_dnn0();
        2: sftw_upr0();
        3: sftw_dnr0();
        4: sftw_upl0();
        default: sftw_dnl0();
      endcase
    end
  endtask

  // ---- the feed steps ----
  task automatic shiftinput_byte(input integer ext);
    begin
      if (stack <= 16) begin
        if (srcbit >= 8) srcbit = srcbit - 8;
        else begin stack = stack + (8 - srcbit); srcbit = 0; end
        if ((r_sft & 16'h1000) == 0) inptr = inptr + 1;
        else                         inptr = inptr - 1;
      end
      srcmask[8*ext +: 8] = 8'hFF;
      sftb0(ext);
    end
  endtask

  task automatic shiftinput_incw();
    begin
      if (stack <= 16) begin
        inptr = inptr + 2;
        if (srcbit >= 8) outptr = outptr + 1;
        stack = stack + (16 - srcbit);
        srcbit = 0;
      end
      srcmask = 16'hFFFF;
      sftw_call();
    end
  endtask

  task automatic shiftinput_decw();
    begin
      if (stack <= 16) begin
        inptr = inptr - 2;
        if (srcbit >= 8) outptr = outptr - 1;
        stack = stack + (16 - srcbit);
        srcbit = 0;
      end
      srcmask = 16'hFFFF;
      sftw_call();
    end
  endtask

  // The feed helpers, EGCOPE_SHIFTB / EGCOPE_SHIFTW in memegc.c.
  task automatic feed_byte_cpu(input integer ext, input [7:0] value);
    begin
      if ((r_ope & 16'h0400) != 0) begin
        ebuf[inptr + 0]  = value;
        ebuf[inptr + 4]  = value;
        ebuf[inptr + 8]  = value;
        ebuf[inptr + 12] = value;
        shiftinput_byte(ext);
      end
    end
  endtask

  // EGCOPE_SHIFTW: guarded by ope & 0x400.
  task automatic feed_word_cpu(input [15:0] value);
    begin
      if ((r_ope & 16'h0400) != 0) feed_word_cpu2(value);
    end
  endtask

  // EGCOPE_SHIFTW2: unconditional (memegc.c egc_opew case 0x1000 and default).
  task automatic feed_word_cpu2(input [15:0] value);
    begin
      if ((r_sft & 16'h1000) == 0) begin
        ebuf[inptr + 0] = value[7:0];  ebuf[inptr + 1] = value[15:8];
        ebuf[inptr + 4] = value[7:0];  ebuf[inptr + 5] = value[15:8];
        ebuf[inptr + 8] = value[7:0];  ebuf[inptr + 9] = value[15:8];
        ebuf[inptr + 12] = value[7:0]; ebuf[inptr + 13] = value[15:8];
        shiftinput_incw();
      end else begin
        ebuf[inptr - 1] = value[7:0];  ebuf[inptr + 0] = value[15:8];
        ebuf[inptr + 3] = value[7:0];  ebuf[inptr + 4] = value[15:8];
        ebuf[inptr + 7] = value[7:0];  ebuf[inptr + 8] = value[15:8];
        ebuf[inptr + 11] = value[7:0]; ebuf[inptr + 12] = value[15:8];
        shiftinput_decw();
      end
    end
  endtask

  // ================================================================
  // The ROP functions (memegc.c ope_xx/ope_np/ope_nd/ope_00/ope_0f/ope_c0/ope_f0/ope_fc/ope_ff)
  // ================================================================
  // pat = the colour quad / the pattern register / the shifter output, per fgbg & 0x6000.
  task automatic rop_pat();
    begin
      case (r_fgbg & 16'h6000)
        16'h2000: begin
          pat_q[0] = bgc[0]; pat_q[1] = bgc[1]; pat_q[2] = bgc[2]; pat_q[3] = bgc[3];
        end
        16'h4000: begin
          pat_q[0] = fgc[0]; pat_q[1] = fgc[1]; pat_q[2] = fgc[2]; pat_q[3] = fgc[3];
        end
        16'h6000: begin
          pat_q[0] = fgc[0]; pat_q[1] = fgc[1]; pat_q[2] = bgc[2]; pat_q[3] = bgc[3];
        end
        default: begin
          if ((r_ope & 16'h0300) == 16'h0100) begin
            pat_q[0] = sft_q[0]; pat_q[1] = sft_q[1]; pat_q[2] = sft_q[2]; pat_q[3] = sft_q[3];
          end else begin
            pat_q[0] = patreg[0]; pat_q[1] = patreg[1];
            pat_q[2] = patreg[2]; pat_q[3] = patreg[3];
          end
        end
      endcase
    end
  endtask

  // The opefn[256] table, as the nine distinct bodies plus the table itself.
  task automatic opefn256(input [7:0] rop, input integer page, input [14:0] off);
    reg [15:0] dstw [0:3];
    integer p;
    begin
      rop_pat();
      for (p = 0; p < 4; p = p + 1)
        dstw[p] = {mem[p][page][(off + 1) & 15'h7fff], mem[p][page][off & 15'h7fff]};
      case (rop)
        8'h00: for (p = 0; p < 4; p = p + 1) rop_res[p] = 16'h0000;
        8'h0f: for (p = 0; p < 4; p = p + 1) rop_res[p] = ~sft_q[p];
        8'hf0: for (p = 0; p < 4; p = p + 1) rop_res[p] = sft_q[p];
        8'hff: for (p = 0; p < 4; p = p + 1) rop_res[p] = 16'hFFFF;
        8'hc0: for (p = 0; p < 4; p = p + 1) rop_res[p] = sft_q[p] & dstw[p];
        8'hfc: for (p = 0; p < 4; p = p + 1)
                 rop_res[p] = sft_q[p] | ((~sft_q[p]) & dstw[p]);
        8'h03, 8'h0c, 8'h30, 8'h33, 8'h3c, 8'h3f,
        8'hc3, 8'hcc, 8'hcf, 8'hf3: for (p = 0; p < 4; p = p + 1)   // ope_np: no pat
          rop_res[p] =
            ((r_ope & 16'h0080) ? (sft_q[p] & dstw[p])        : 16'h0000) |
            ((r_ope & 16'h0020) ? (sft_q[p] & (~dstw[p]))     : 16'h0000) |
            ((r_ope & 16'h0008) ? ((~sft_q[p]) & dstw[p])     : 16'h0000) |
            ((r_ope & 16'h0002) ? ((~sft_q[p]) & (~dstw[p]))  : 16'h0000);
        8'h05, 8'h0a, 8'h50, 8'h55, 8'h5a, 8'h5f,
        8'ha0, 8'ha5, 8'haa, 8'haf, 8'hf5, 8'hfa: for (p = 0; p < 4; p = p + 1)  // ope_nd: no dst
          rop_res[p] =
            ((r_ope & 16'h0080) ? (pat_q[p] & sft_q[p])       : 16'h0000) |
            ((r_ope & 16'h0040) ? ((~pat_q[p]) & sft_q[p])    : 16'h0000) |
            ((r_ope & 16'h0008) ? (pat_q[p] & (~sft_q[p]))    : 16'h0000) |
            ((r_ope & 16'h0004) ? ((~pat_q[p]) & (~sft_q[p])) : 16'h0000);
        default: for (p = 0; p < 4; p = p + 1)                       // ope_xx: pat, src, dst
          rop_res[p] =
            ((r_ope & 16'h0080) ? (pat_q[p] & sft_q[p] & dstw[p])         : 16'h0000) |
            ((r_ope & 16'h0040) ? ((~pat_q[p]) & sft_q[p] & dstw[p])      : 16'h0000) |
            ((r_ope & 16'h0020) ? (pat_q[p] & sft_q[p] & (~dstw[p]))      : 16'h0000) |
            ((r_ope & 16'h0010) ? ((~pat_q[p]) & sft_q[p] & (~dstw[p]))   : 16'h0000) |
            ((r_ope & 16'h0008) ? (pat_q[p] & (~sft_q[p]) & dstw[p])      : 16'h0000) |
            ((r_ope & 16'h0004) ? ((~pat_q[p]) & (~sft_q[p]) & dstw[p])   : 16'h0000) |
            ((r_ope & 16'h0002) ? (pat_q[p] & (~sft_q[p]) & (~dstw[p]))   : 16'h0000) |
            ((r_ope & 16'h0001) ? ((~pat_q[p]) & (~sft_q[p]) & (~dstw[p])): 16'h0000);
      endcase
    end
  endtask

  // ================================================================
  // egc_opeb / egc_opew (memegc.c): fill dqw[p] and mask2.
  // ================================================================
  task automatic egc_opeb(input [31:0] addr, input [7:0] value);
    integer ext;
    begin
      ext = addr & 1;
      mask2 = r_mask;
      case (r_ope & 16'h1800)
        16'h0800: begin
          feed_byte_cpu(ext, value);
          mask2 = mask2 & srcmask;
          opefn256(r_ope[7:0], (addr >> 20) & 1, addr[15:0] & 15'hFFFE);
          for (integer p = 0; p < 4; p = p + 1) dqw[p] = rop_res[p];
        end
        16'h1000: begin
          if ((r_fgbg & 16'h6000) == 16'h2000) begin
            for (integer p = 0; p < 4; p = p + 1) dqw[p] = bgc[p];
          end else if ((r_fgbg & 16'h6000) == 16'h4000) begin
            for (integer p = 0; p < 4; p = p + 1) dqw[p] = fgc[p];
          end else begin
            feed_byte_cpu(ext, value);
            mask2 = mask2 & srcmask;
            for (integer p = 0; p < 4; p = p + 1) dqw[p] = sft_q[p];
          end
        end
        default: begin
          for (integer p = 0; p < 4; p = p + 1) dqw[p] = {value, value};
        end
      endcase
    end
  endtask

  task automatic egc_opew(input [31:0] addr, input [15:0] value);
    begin
      mask2 = r_mask;
      case (r_ope & 16'h1800)
        16'h0800: begin
          feed_word_cpu(value);
          mask2 = mask2 & srcmask;
          opefn256(r_ope[7:0], (addr >> 20) & 1, addr[15:0]);
          for (integer p = 0; p < 4; p = p + 1) dqw[p] = rop_res[p];
        end
        16'h1000: begin
          feed_word_cpu2(value);
          mask2 = mask2 & srcmask;
          if ((r_fgbg & 16'h6000) == 16'h2000) begin
            for (integer p = 0; p < 4; p = p + 1) dqw[p] = bgc[p];
          end else if ((r_fgbg & 16'h6000) == 16'h4000) begin
            for (integer p = 0; p < 4; p = p + 1) dqw[p] = fgc[p];
          end else begin
            for (integer p = 0; p < 4; p = p + 1) dqw[p] = patreg[p];
          end
        end
        default: begin
          for (integer p = 0; p < 4; p = p + 1) dqw[p] = value;
          feed_word_cpu2(value);
          mask2 = mask2 & srcmask;
        end
      endcase
    end
  endtask

  // ================================================================
  // The read and write paths (memegc.c egc_readbyte/writebyte/readword/writeword)
  // ================================================================
  // `plane` is the addressed window plane, `off` the byte offset inside the window,
  // `page` the 0xA6 access page. Writes fold to the offset and hit all four planes;
  // reads keep the window plane for the raw memory return.
  task automatic write8(input integer page, input integer plane, input [14:0] off, input [7:0] value);
    integer ext;
    integer p;
    reg [7:0] old;
    begin
      ext = off & 1;
      if ((r_ope & 16'h0300) == 16'h0200)
        for (p = 0; p < 4; p = p + 1)
          patreg[p][8*ext +: 8] = mem[p][page][off & 15'h7FFF];
      egc_opeb({page, 8'd0, off}, value);
      if (mask2[8*ext +: 8] != 8'h00)
        for (p = 0; p < 4; p = p + 1)
          if ((r_access & (1 << p)) == 0) begin
            old = mem[p][page][off & 15'h7FFF];
            mem[p][page][off & 15'h7FFF] =
              (old & ~mask2[8*ext +: 8]) | (dqw[p][8*ext +: 8] & mask2[8*ext +: 8]);
          end
    end
  endtask

  task automatic write16(input integer page, input integer plane, input [14:0] off, input [15:0] value);
    integer p;
    begin
      if ((r_ope & 16'h0300) == 16'h0200)
        for (p = 0; p < 4; p = p + 1)
          patreg[p] = {mem[p][page][(off + 1) & 15'h7FFF], mem[p][page][off & 15'h7FFF]};
      egc_opew({page, 8'd0, off}, value);
      if (mask2 != 16'h0000)
        for (p = 0; p < 4; p = p + 1)
          if ((r_access & (1 << p)) == 0) begin
            mem[p][page][off & 15'h7FFF] =
              (mem[p][page][off & 15'h7FFF] & ~mask2[7:0]) | (dqw[p][7:0] & mask2[7:0]);
            mem[p][page][(off + 1) & 15'h7FFF] =
              (mem[p][page][(off + 1) & 15'h7FFF] & ~mask2[15:8]) | (dqw[p][15:8] & mask2[15:8]);
          end
    end
  endtask

  task automatic read8(input integer page, input integer plane, input [14:0] off,
                       output [7:0] dout);
    integer ext, pl, p;
    begin
      ext = off & 1;
      pl = (r_fgbg >> 8) & 3;
      for (p = 0; p < 4; p = p + 1)
        lastvram[p][8*ext +: 8] = mem[p][page][off & 15'h7FFF];
      if ((r_ope & 16'h0400) == 0) begin
        ebuf[inptr + 0]  = lastvram[0][8*ext +: 8];
        ebuf[inptr + 4]  = lastvram[1][8*ext +: 8];
        ebuf[inptr + 8]  = lastvram[2][8*ext +: 8];
        ebuf[inptr + 12] = lastvram[3][8*ext +: 8];
        shiftinput_byte(ext);
      end
      // PLOAD_R (RL_MEMREAD), the machine's two read kinds: a COMPAREREAD (OPE bit 13, the
      // 0x3100 the games set up) captures ALL FOUR planes from one read
      // (EGCREAD.CSV RD17_P_*, compare-plus-pload-captured-source), a normal read captures the
      // SELECTED PAT plane only (RD02_PAT_S0..S3, B05_PLOAD_READ). RTL: pc9821_egc.sv's
      // `if (ope_cmprd)` read latch; README.TXT's rule "Normal PLOAD_R loads the selected PAT
      // plane only ... Compare+PLOAD_R is tested separately" is this split.
      if ((r_ope & 16'h0300) == 16'h0100) begin
        if ((r_ope & 16'h2000) != 0)
          for (p = 0; p < 4; p = p + 1)
            patreg[p][8*ext +: 8] = mem[p][page][off & 15'h7FFF];
        else
          patreg[pl][8*ext +: 8] = mem[pl][page][off & 15'h7FFF];
      end
      if ((r_ope & 16'h2000) == 0) begin
        if ((r_ope & 16'h0400) == 0) dout = sft_q[pl][8*ext +: 8];
        else                         dout = mem[pl][page][off & 15'h7FFF];
      end else begin
        // COMPAREREAD, unconditional on 0x4A2's pattern source (see read16 below).
        dout = 8'hFF;
        for (p = 0; p < 4; p = p + 1)
          if ((r_access & (1 << p)) == 0)
            dout = dout & ~(mem[p][page][off & 15'h7FFF] ^ fgc[p][7:0]);
      end
    end
  endtask

  task automatic read16(input integer page, input integer plane, input [14:0] off,
                        output [15:0] dout);
    integer pl, p;
    begin
      pl = (r_fgbg >> 8) & 3;
      for (p = 0; p < 4; p = p + 1)
        lastvram[p] = {mem[p][page][(off + 1) & 15'h7FFF], mem[p][page][off & 15'h7FFF]};
      if ((r_ope & 16'h0400) == 0) begin
        if ((r_sft & 16'h1000) == 0) begin
          ebuf[inptr + 0] = lastvram[0][7:0];  ebuf[inptr + 1] = lastvram[0][15:8];
          ebuf[inptr + 4] = lastvram[1][7:0];  ebuf[inptr + 5] = lastvram[1][15:8];
          ebuf[inptr + 8] = lastvram[2][7:0];  ebuf[inptr + 9] = lastvram[2][15:8];
          ebuf[inptr + 12] = lastvram[3][7:0]; ebuf[inptr + 13] = lastvram[3][15:8];
          shiftinput_incw();
        end else begin
          ebuf[inptr - 1] = lastvram[0][7:0];  ebuf[inptr + 0] = lastvram[0][15:8];
          ebuf[inptr + 3] = lastvram[1][7:0];  ebuf[inptr + 4] = lastvram[1][15:8];
          ebuf[inptr + 7] = lastvram[2][7:0];  ebuf[inptr + 8] = lastvram[2][15:8];
          ebuf[inptr + 11] = lastvram[3][7:0]; ebuf[inptr + 12] = lastvram[3][15:8];
          shiftinput_decw();
        end
      end
      // See the byte path above for the two read kinds' rule (RD17_P_* vs RD02_PAT_S0..S3).
      if ((r_ope & 16'h0300) == 16'h0100) begin
        if ((r_ope & 16'h2000) != 0)
          for (p = 0; p < 4; p = p + 1)
            patreg[p] = lastvram[p];
        else
          patreg[pl] = lastvram[pl];
      end
      if ((r_ope & 16'h2000) == 0) begin
        if ((r_ope & 16'h0400) == 0) dout = sft_q[pl];
        else                         dout = {mem[pl][page][(off + 1) & 15'h7FFF],
                                            mem[pl][page][off & 15'h7FFF]};
      end else begin
        // COMPAREREAD: the AND over the ACCESS-enabled planes of (plane data == the retained FG
        // colour's bit for that plane), whatever 0x4A2's pattern source says - the machine compares
        // in the PAT mode too (EKGCREAD.CSV RD22_PATSEL; CK00_*_MASK/B08_CMP_*/RD10_RAMP_* are
        // driven with the PAT source, witnessed by the pre-fix core's raw-plane column). The
        // machine's EGCREAD/EGCQUIRK CSVs are the source (docs/probes/egc-conformance/); NP2kai
        // has no compare at all and MAME gates the REFERENCE on 0x4A2, so both are superseded.
        dout = 16'hFFFF;
        for (p = 0; p < 4; p = p + 1)
          if ((r_access & (1 << p)) == 0)
            dout = dout & ~(lastvram[p] ^ fgc[p]);
      end
    end
  endtask

  // ================================================================
  // memegc_rd8/wr8/rd16/wr16/rd32/wr32 -- the CPU access dispatch
  // ================================================================
  // The unit walk below is RE-DERIVED from NP2kai's dispatch (mem/memegc.c:1379-1424:
  // memegc_wr8/rd8 -> egc_writebyte/readbyte; memegc_wr16/rd16 at an EVEN address ->
  // egc_writeword/readword, at an ODD address -> two byte ops, HIGH-byte-first when
  // egc.sft bit 12 is set (:1385-1404); memegc_wr32/rd32 -> wr16/rd16 at addr then
  // addr+2, in that order unconditionally (:1417-1424)), combined with the z486 beat
  // split (src/z486/z486_pkg.sv:1169 `calc_be`, :1226 `calc_be_first`, :1242
  // `calc_be_second`). Every byte-enable set a real x86 access generates maps to a
  // UNIQUE memegc dispatch of its bytes:
  //
  //   be set       generated by (calc_be*)              memegc dispatch of the bytes
  //   0001/0010/   byte MOV (calc_be op_size 0)         wr8                        -> one byte unit
  //   0100/1000    also word@3 / dword@1,3 halves       wr16(odd) halves = wr8     -> byte unit
  //   0011         word@0 (calc_be) / dword@2 2nd       wr16(even)                 -> word unit lane 0
  //   1100         word@2 (calc_be) / dword@2 1st       wr16(even)                 -> word unit lane 2
  //   1111         dword@0 (calc_be)                    wr32(0)=wr16(0)+wr16(2)    -> word units lane 0, 2
  //   0110         word@1 (calc_be)                     wr16(odd)=wr8+wr8          -> byte pair (1,2), dir-split
  //   1110         dword@1 1st (calc_be_first)          wr32(1)=wr16(1)+wr16(3),   -> bytes (1,2) dir-split,
  //                                                     BOTH odd                   then byte 3
  //   0111         dword@3 2nd (calc_be_second)         wr32(3)=wr16(3)+wr16(5),   -> byte 4, then bytes (5,6)
  //                                                     BOTH odd                   dir-split
  //
  // The unaligned-dword halves (1110/0111) are therefore ALL-BYTE walks grouped by
  // the odd wr16 pairs - NOT "a 16-bit unit at even lanes": memegc_wr16 at an odd
  // address never calls egc_writeword (memegc.c:1395-1404), and an unaligned dword is
  // two odd wr16s. The descending (egc.sft bit 12) order runs each odd pair's HIGH
  // byte first; a pair whose far byte lives in the neighbouring beat keeps its
  // beat-local order (the cross-beat order of memegc's logical dispatch vs the 486's
  // beat order is capture-pending on real hardware; the beat-local restriction of
  // memegc's order is what is modelled here).
  //
  // The hole sets (0101, 1001, 1010, 1011, 1101) have NO memegc counterpart and NO
  // generating x86 shape (calc_be* never emits them): they are a SELF-CONSISTENCY
  // PIN of the lane walk only (a set of enabled lanes is a set of bytes the CPU wrote,
  // so a hole must not drop the lanes beyond it) and are excluded from the
  // conformance count in tb_pc9821_egc_conformance section 1.
  task automatic op(input integer page, input integer plane, input [14:0] base,
                    input [31:0] din, input [3:0] be, input integer wr, output [31:0] dout);
    /* verilator no_inline_task */
    integer lane, nxt, idx, k, nsteps;
    integer steps [0:3];           // lane + 4 for a 16-bit unit, in run order
    reg [15:0] rdw;
    reg [7:0]  rdb;
    reg        desc;
    begin
      dout = 32'hFFFF_FFFF;
      desc = (r_sft & 16'h1000) != 0;
      nsteps = 0;
      case (be)
        4'b0001, 4'b0010, 4'b0100, 4'b1000: begin   // one byte unit (wr8 at its address)
          steps[0] = be[0] ? 0 : be[1] ? 1 : be[2] ? 2 : 3;
          nsteps = 1;
        end
        4'b0011: begin steps[0] = 4; nsteps = 1; end                    // wr16(even) at lane 0
        4'b1100: begin steps[0] = 4 + 2; nsteps = 1; end                // wr16(even) at lane 2
        4'b1111: begin steps[0] = 4; steps[1] = 4 + 2; nsteps = 2; end  // wr32(0) = wr16(0), wr16(2)
        4'b0110: begin                                                  // wr16(odd) pair (1,2)
          if (desc) begin steps[0] = 2; steps[1] = 1; end
          else          begin steps[0] = 1; steps[1] = 2; end
          nsteps = 2;
        end
        4'b1110: begin                    // dword@1 1st half: wr16(odd) (1,2), then wr16(3)'s byte 3
          if (desc) begin steps[0] = 2; steps[1] = 1; end
          else          begin steps[0] = 1; steps[1] = 2; end
          steps[2] = 3;
          nsteps = 3;
        end
        4'b0111: begin                    // dword@3 2nd half: wr16(3)'s byte 4, then wr16(odd) (5,6)
          steps[0] = 0;
          if (desc) begin steps[1] = 2; steps[2] = 1; end
          else          begin steps[1] = 1; steps[2] = 2; end
          nsteps = 3;
        end
        default: begin
          // The synthetic hole sets (0101, 1001, 1010, 1011, 1101): the lane walk pin.
          lane = be[0] ? 0 : be[1] ? 1 : be[2] ? 2 : be[3] ? 3 : 4;
          while (lane <= 3) begin
            if ((lane[0] == 1'b0) && (lane != 3) && be[lane] && be[lane + 1]) begin
              steps[nsteps] = 4 + lane;   // a 16-bit unit at an even, fully enabled pair
              nxt = lane + 2;
            end else begin
              steps[nsteps] = lane;       // a byte unit
              nxt = lane + 1;
            end
            nsteps = nsteps + 1;
            // The walk continues at the next ENABLED lane, not at the next lane: cpu_be's
            // enabled lanes are bytes the CPU wrote, so a hole must not drop the lanes
            // beyond it.
            lane = 4;
            for (k = 3; k >= 0; k = k - 1)
              if (be[k] && (k >= nxt)) lane = k;
          end
        end
      endcase
      for (k = 0; k < nsteps; k = k + 1) begin
        lane = steps[k] & 3;
        idx = (lane >= 2) ? 1 : 0;
        if (steps[k] >= 4) begin                                               // a 16-bit unit
          if (wr != 0) write16(page, plane, base + lane[14:0], din[16*idx +: 16]);
          else begin
            read16(page, plane, base + lane[14:0], rdw);
            dout[16*idx +: 16] = rdw;
          end
        end else begin                                                        // a byte unit
          if (wr != 0) write8(page, plane, base + lane[14:0], din[8*lane +: 8]);
          else begin
            read8(page, plane, base + lane[14:0], rdb);
            dout[8*lane +: 8] = rdb;
          end
        end
      end
    end
  endtask

  // The LOGICAL CPU access dispatch: a verbatim transcription of memegc.c:1379-1424
  // (memegc_wr8/rd8 -> egc_writebyte/readbyte; memegc_wr16/rd16: EVEN address -> one
  // egc_writeword/readword, ODD address -> two byte ops, HIGH byte first when egc.sft
  // bit 12 is set; memegc_wr32/rd32 -> wr16/rd16 at addr then addr+2, unconditionally).
  // tb_pc9821_egc_conformance section 1's pair cases drive the OCCURRING x86 shapes
  // through these entry points and split them into the z486 beats (calc_be_first/
  // calc_be_second, src/z486/z486_pkg.sv:1226/:1242) only on the DUT side, so the
  // gold carries no beat-level rule of its own at all.
  task automatic op8(input integer page, input integer plane, input [14:0] addr,
                     input [7:0] din, input integer wr, output [7:0] dout);
    /* verilator no_inline_task */
    reg [7:0] rdb;
    begin
      if (wr != 0) write8(page, plane, addr, din);           // memegc.c:1410-1413
      else begin read8(page, plane, addr, rdb); dout = rdb; end  // :1380-1383
    end
  endtask

  task automatic op16(input integer page, input integer plane, input [14:0] addr,
                      input [15:0] din, input integer wr, output [15:0] dout);
    /* verilator no_inline_task */
    reg [15:0] rdw;
    reg [7:0]  rdb, rdb2;
    begin
      dout = 16'hFFFF;
      if ((addr & 1) == 0) begin                             // memegc.c:1385-1387 / :1394-1396
        if (wr != 0) write16(page, plane, addr, din);
        else begin read16(page, plane, addr, rdw); dout = rdw; end
      end else if ((r_sft & 16'h1000) == 0) begin            // ascending: low byte first (:1388-1392, :1397-1401)
        if (wr != 0) begin
          write8(page, plane, addr, din[7:0]);
          write8(page, plane, addr + 1, din[15:8]);
        end else begin
          read8(page, plane, addr, rdb); read8(page, plane, addr + 1, rdb2);
          dout = {rdb2, rdb};
        end
      end else begin                                          // descending: high byte first (:1393-1404)
        if (wr != 0) begin
          write8(page, plane, addr + 1, din[15:8]);
          write8(page, plane, addr, din[7:0]);
        end else begin
          read8(page, plane, addr + 1, rdb2); read8(page, plane, addr, rdb);
          dout = {rdb2, rdb};
        end
      end
    end
  endtask

  task automatic op32(input integer page, input integer plane, input [14:0] addr,
                      input [31:0] din, input integer wr, output [31:0] dout);
    /* verilator no_inline_task */
    reg [15:0] lo, hi;
    begin
      dout = 32'hFFFF_FFFF;
      // memegc.c:1417-1424: the low halfword at addr, then the high halfword at addr+2.
      op16(page, plane, addr, din[15:0], wr, lo);
      op16(page, plane, addr + 2, din[31:16], wr, hi);
      dout = {hi, lo};
    end
  endtask

  // Raw plane byte store, no EGC: the bench's seed operand.
  task automatic seed(input integer page, input integer plane, input [14:0] off, input [7:0] v);
    /* verilator no_inline_task */
    begin mem[plane][page][off & 15'h7FFF] = v; end
  endtask

  function [7:0] peek(input integer page, input integer plane, input [14:0] off);
    peek = mem[plane][page][off & 15'h7FFF];
  endfunction

endmodule

/* verilator lint_on WIDTHEXPAND */
/* verilator lint_on WIDTHTRUNC */

`default_nettype wire
