`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_EGC_SHIFT: drives the real pc9821_egc shifter directly, through a four-plane D1 model, and asserts every emitted word byte-by-byte against a port of NP2kai mem/memegc.c's shifter (egcshift, shiftinput_incw/decw, egcsftb_*/egcsftw_*): the 0x28F0 shake form, where the source read feeds the shifter and the write stores the ROP src, and the 0x0CF0 write-feed form, where NP2kai's EGCOPE_SHIFTW feeds from the CPU word. It sweeps the sft src_bit/dst_bit field, the bit-length register (0x4AE) at 1, 8, 16, 17 and 640 dots, the descending direction (sft bit 12), and master.lib's egc_shift_left_all and egc_shift_left register values. It is FAIL-FIRST: the deviations recorded against NP2kai - the re-arm's un-cleared stack, the whole-byte src_bit/dst_bit difference sft_moved ignores, and the missing descending dnr window - make it fail, one named MISMATCH line per unit. Section 6 is the review egc.md F1 regression: a NO-ARM-AFTER-RESET store must be bit-correct (NP2kai's egc_reset arms remain = 16, so the first post-reset produce masks 0xFFFF and not 0x0080). Section 7 is the F2 regression: the MISALIGNED 16-bit split (be = 0110) is memegc_wr16/rd16 at an ODD address - two byte operations run HIGH-byte-first when sft bit 12 is set - driven in both feeding shapes (the 0x28F0 read-feed blit and the 0x0CF0 write feed), against the same NP2kai port with the byte feed (EGCOPE_SHIFTB / shiftinput_byte / egcsftb_*0).
module tb_pc9821_egc_shift;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  localparam integer NBUF  = 2048;
  localparam integer NBASE = 1024;

  // ==== DUT ====
  reg [15:0] reg_access   = 16'hFFF0;
  reg [15:0] reg_fgbg     = 16'h00FF;
  reg [15:0] reg_ope      = 16'h28F0;
  reg [15:0] reg_fg       = 16'h0000;
  reg [15:0] reg_mask     = 16'hFFFF;
  reg [15:0] reg_bg       = 16'h0000;
  reg [15:0] reg_sft      = 16'h0000;
  reg [15:0] reg_leng     = 16'h000F;
  reg        reg_shift_we = 1'b0;
  reg        cpu_page     = 1'b0;
  reg [14:0] cpu_offset   = 15'd0;
  reg [1:0]  cpu_plane    = 2'd0;
  reg [31:0] cpu_din      = 32'd0;
  reg [3:0]  cpu_be       = 4'b0011;
  reg        cpu_valid    = 1'b0;
  reg        cpu_write    = 1'b0;
  wire [31:0] cpu_dout;
  wire        cpu_ready, cpu_resp_valid;
  wire        cl_valid, cl_write;
  wire [15:0] cl_addr;
  wire [31:0] cl_wdata;
  wire [3:0]  cl_wbe;
  wire        cl_burst;
  wire [63:0] cl_wdata2;
  wire [31:0] cl_rdata;
  wire        cl_done;
  reg         cl_ready;

  pc9821_egc dut (
      .clk(clk), .reset(reset),
      .reg_access(reg_access), .reg_fgbg(reg_fgbg), .reg_ope(reg_ope),
      .reg_fg(reg_fg), .reg_mask(reg_mask), .reg_bg(reg_bg),
      .reg_sft(reg_sft), .reg_leng(reg_leng), .reg_shift_we(reg_shift_we),
      .cpu_page(cpu_page), .cpu_plane(cpu_plane), .cpu_offset(cpu_offset),
      .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_dout(cpu_dout), .cpu_ready(cpu_ready),
      .cpu_resp_valid(cpu_resp_valid),
      .cl_valid(cl_valid), .cl_ready(cl_ready), .cl_write(cl_write),
      .cl_addr(cl_addr), .cl_wdata(cl_wdata), .cl_wbe(cl_wbe),
      .cl_burst(cl_burst), .cl_wdata2(cl_wdata2),
      .cl_rdata(cl_rdata), .cl_done(cl_done)
  );

  // ==== D1 MODEL: four byte planes indexed by {page, column} ====
  // One D1 column is one byte of every plane at cl_addr. A read request is the run
  // [first .. last] the request's byte enables cover, answered one cl_done per column;
  // a write is one column per request, or two when cl_burst carries cl_wdata2.
  reg [7:0] mem [0:3][0:65535];

  reg  [1:0]  mst    = 2'd0;
  reg  [15:0] m_rdcol = 16'd0;
  reg  [3:0]  m_left  = 4'd0;

  wire m_done = (mst == 2'd1) || (mst == 2'd2);

  assign cl_ready = (mst == 2'd0);
  assign cl_done  = m_done;
  assign cl_rdata = {mem[3][m_rdcol], mem[2][m_rdcol], mem[1][m_rdcol], mem[0][m_rdcol]};

  function [2:0] hi_col(input [3:0] we);
    begin
      hi_col = we[3] ? 3'd3 : we[2] ? 3'd2 : we[1] ? 3'd1 : 3'd0;
    end
  endfunction

  task automatic wr_col(input [15:0] col, input [31:0] data, input [3:0] we);
    integer p;
    begin
      for (p = 0; p < 4; p = p + 1)
        if (we[p]) mem[p][col] = data[8 * p +: 8];
    end
  endtask

  integer mi;
  initial for (mi = 0; mi < 65536; mi = mi + 1) begin
    mem[0][mi] = 8'h00; mem[1][mi] = 8'h00; mem[2][mi] = 8'h00; mem[3][mi] = 8'h00;
  end

  always @(posedge clk) begin
    if (reset) begin
      mst <= 2'd0; m_rdcol <= 16'd0; m_left <= 4'd0;
    end else begin
      case (mst)
        2'd0: if (cl_valid && cl_ready) begin
          if (cl_write) begin
            if (cl_burst) begin
              wr_col(cl_addr, cl_wdata2[31:0], 4'hF);
              wr_col(cl_addr + 16'd1, cl_wdata2[63:32], 4'hF);
            end else begin
              wr_col(cl_addr, cl_wdata, cl_wbe);
              mst <= 2'd2;
            end
          end else begin
            m_rdcol <= cl_addr;
            m_left  <= hi_col(cl_wbe) - {1'b0, cl_addr[1:0]} + 4'd1;
            mst     <= 2'd1;
          end
        end
        2'd1: if (m_left == 4'd1) mst <= 2'd0;
              else begin m_rdcol <= m_rdcol + 16'd1; m_left <= m_left - 4'd1; end
        2'd2: mst <= 2'd0;
      endcase
    end
  end

  // ==== NP2KAI REFERENCE (mem/memegc.c): the shifter, ported for plane 0 ====
  // The four planes carry identical bytes in every case here, so one plane's byte
  // stream models them all. nbuf[n_inptr + 4p] is plane p's byte, so plane 0 is at
  // n_inptr + 0/+1; the counter's byte stream is the only state that can diverge.
  reg  [7:0] nbuf [0:NBUF-1];
  integer n_inptr, n_outptr, n_remain, n_func, n_stack;
  integer n_srcbit, n_dstbit, n_sft8bitl, n_sft8bitr;
  reg [7:0]  n_srcmask [0:1];
  reg [7:0]  n_sdata [0:1];
  reg [15:0] n_sft_d, n_leng_d;
  function [7:0] brev(input [7:0] v);
    integer k;
    begin
      for (k = 0; k < 8; k = k + 1) brev[k] = v[7 - k];
    end
  endfunction

  // bytemask_u0[start][len-1]: start is the destination bit address, len the run length.
  // NP2kai indexes it as dstbit + (len-1)*8, i.e. row = len-1, column = start.
  function [7:0] bm_u0(input integer start, input integer len1);
    begin
      bm_u0 = (8'hFF << (7 - len1)) >> start;
    end
  endfunction

  function [7:0] bm_u1(input integer len1);
    begin
      bm_u1 = 8'hFF << (7 - len1);
    end
  endfunction

  task automatic n_egcshift;
    integer src8, dst8;
    begin
      n_remain = (n_leng_d & 16'h0FFF) + 1;
      n_func   = (n_sft_d >> 12) & 1;
      if (!n_func) begin n_inptr = NBASE; n_outptr = NBASE; end
      else         begin n_inptr = NBASE + 512 + 3; n_outptr = NBASE + 512 + 3; end
      n_srcbit = n_sft_d & 16'h000F;
      n_dstbit = (n_sft_d >> 4) & 16'h000F;
      src8 = n_srcbit & 7;
      dst8 = n_dstbit & 7;
      if (src8 < dst8) begin
        n_func += 2; n_sft8bitr = dst8 - src8; n_sft8bitl = 8 - n_sft8bitr;
      end else if (src8 > dst8) begin
        n_func += 4; n_sft8bitl = src8 - dst8; n_sft8bitr = 8 - n_sft8bitl;
      end
      n_stack = 0;
    end
  endtask

  // egcsftb_*_sub: one output byte's mask and data.
  task automatic n_sub_upn(input integer ext);
    begin
      if (n_dstbit >= 8) begin n_dstbit -= 8; n_srcmask[ext] = 0; end
      else begin
        if (n_dstbit != 0) begin
          if (n_dstbit + n_remain >= 8) begin
            n_srcmask[ext] = bm_u0(n_dstbit, 7); n_remain -= (8 - n_dstbit);
          end else begin
            n_srcmask[ext] = bm_u0(n_dstbit, n_remain - 1); n_remain = 0;
          end
          n_dstbit = 0;
        end else begin
          if (n_remain >= 8) n_remain -= 8;
          else begin n_srcmask[ext] = bm_u1(n_remain - 1); n_remain = 0; end
        end
        n_sdata[ext] = nbuf[n_outptr];
        n_outptr = n_outptr + 1;
      end
    end
  endtask

  task automatic n_sub_dnn(input integer ext);
    begin
      if (n_dstbit >= 8) begin n_dstbit -= 8; n_srcmask[ext] = 0; end
      else begin
        if (n_dstbit != 0) begin
          if (n_dstbit + n_remain >= 8) begin
            n_srcmask[ext] = brev(bm_u0(n_dstbit, 7)); n_remain -= (8 - n_dstbit);
          end else begin
            n_srcmask[ext] = brev(bm_u0(n_dstbit, n_remain - 1)); n_remain = 0;
          end
          n_dstbit = 0;
        end else begin
          if (n_remain >= 8) n_remain -= 8;
          else begin n_srcmask[ext] = brev(bm_u1(n_remain - 1)); n_remain = 0; end
        end
        n_sdata[ext] = nbuf[n_outptr];
        n_outptr = n_outptr - 1;
      end
    end
  endtask

  task automatic n_sub_upr(input integer ext);
    begin
      if (n_dstbit >= 8) begin n_dstbit -= 8; n_srcmask[ext] = 0; end
      else begin
        if (n_dstbit != 0) begin
          if (n_dstbit + n_remain >= 8) begin
            n_srcmask[ext] = bm_u0(n_dstbit, 7); n_remain -= (8 - n_dstbit);
          end else begin
            n_srcmask[ext] = bm_u0(n_dstbit, n_remain - 1); n_remain = 0;
          end
          n_dstbit = 0;
          n_sdata[ext] = (nbuf[n_outptr] >> n_sft8bitr) & 8'hFF;
        end else begin
          if (n_remain >= 8) n_remain -= 8;
          else begin n_srcmask[ext] = bm_u1(n_remain - 1); n_remain = 0; end
          n_sdata[ext] = ((nbuf[n_outptr] << n_sft8bitl) |
                          (nbuf[n_outptr + 1] >> n_sft8bitr)) & 8'hFF;
          n_outptr = n_outptr + 1;
        end
      end
    end
  endtask

  task automatic n_sub_dnr(input integer ext);
    begin
      if (n_dstbit >= 8) begin n_dstbit -= 8; n_srcmask[ext] = 0; end
      else begin
        if (n_dstbit != 0) begin
          if (n_dstbit + n_remain >= 8) begin
            n_srcmask[ext] = brev(bm_u0(n_dstbit, 7)); n_remain -= (8 - n_dstbit);
          end else begin
            n_srcmask[ext] = brev(bm_u0(n_dstbit, n_remain - 1)); n_remain = 0;
          end
          n_dstbit = 0;
          n_sdata[ext] = (nbuf[n_outptr] << n_sft8bitr) & 8'hFF;
        end else begin
          if (n_remain >= 8) n_remain -= 8;
          else begin n_srcmask[ext] = brev(bm_u1(n_remain - 1)); n_remain = 0; end
          n_outptr = n_outptr - 1;
          n_sdata[ext] = ((nbuf[n_outptr + 1] >> n_sft8bitl) |
                          (nbuf[n_outptr] << n_sft8bitr)) & 8'hFF;
        end
      end
    end
  endtask

  task automatic n_sub_upl(input integer ext);
    begin
      if (n_dstbit >= 8) begin n_dstbit -= 8; n_srcmask[ext] = 0; end
      else begin
        if (n_dstbit != 0) begin
          if (n_dstbit + n_remain >= 8) begin
            n_srcmask[ext] = bm_u0(n_dstbit, 7); n_remain -= (8 - n_dstbit);
          end else begin
            n_srcmask[ext] = bm_u0(n_dstbit, n_remain - 1); n_remain = 0;
          end
          n_dstbit = 0;
        end else begin
          if (n_remain >= 8) n_remain -= 8;
          else begin n_srcmask[ext] = bm_u1(n_remain - 1); n_remain = 0; end
        end
        n_sdata[ext] = ((nbuf[n_outptr] << n_sft8bitl) |
                        (nbuf[n_outptr + 1] >> n_sft8bitr)) & 8'hFF;
        n_outptr = n_outptr + 1;
      end
    end
  endtask

  task automatic n_sub_dnl(input integer ext);
    begin
      if (n_dstbit >= 8) begin n_dstbit -= 8; n_srcmask[ext] = 0; end
      else begin
        if (n_dstbit != 0) begin
          if (n_dstbit + n_remain >= 8) begin
            n_srcmask[ext] = brev(bm_u0(n_dstbit, 7)); n_remain -= (8 - n_dstbit);
          end else begin
            n_srcmask[ext] = brev(bm_u0(n_dstbit, n_remain - 1)); n_remain = 0;
          end
          n_dstbit = 0;
        end else begin
          if (n_remain >= 8) n_remain -= 8;
          else begin n_srcmask[ext] = brev(bm_u1(n_remain - 1)); n_remain = 0; end
        end
        n_outptr = n_outptr - 1;
        n_sdata[ext] = ((nbuf[n_outptr + 1] >> n_sft8bitl) |
                        (nbuf[n_outptr] << n_sft8bitr)) & 8'hFF;
      end
    end
  endtask

  // egcsftw_*0: the stack gate, the two-byte produce and the re-arm.
  task automatic n_gate(input integer room);
    begin
      n_srcmask[0] = 0; n_srcmask[1] = 0;
    end
  endtask

  task automatic n_w_upn;
    begin
      if (n_stack < (16 - n_dstbit)) n_gate(0);
      else begin
        n_stack -= (16 - n_dstbit);
        n_sub_upn(0);
        if (n_remain != 0) begin n_sub_upn(1); if (n_remain == 0) n_egcshift(); end
        else begin n_srcmask[1] = 0; n_egcshift(); end
      end
    end
  endtask

  task automatic n_w_dnn;
    begin
      if (n_stack < (16 - n_dstbit)) n_gate(0);
      else begin
        n_stack -= (16 - n_dstbit);
        n_sub_dnn(1);
        if (n_remain != 0) begin n_sub_dnn(0); if (n_remain == 0) n_egcshift(); end
        else begin n_srcmask[0] = 0; n_egcshift(); end
      end
    end
  endtask

  task automatic n_w_upr;
    begin
      if (n_stack < (16 - n_dstbit)) n_gate(0);
      else begin
        n_stack -= (16 - n_dstbit);
        n_sub_upr(0);
        if (n_remain != 0) begin n_sub_upr(1); if (n_remain == 0) n_egcshift(); end
        else begin n_srcmask[1] = 0; n_egcshift(); end
      end
    end
  endtask

  task automatic n_w_dnr;
    begin
      if (n_stack < (16 - n_dstbit)) n_gate(0);
      else begin
        n_stack -= (16 - n_dstbit);
        n_sub_dnr(1);
        if (n_remain != 0) begin n_sub_dnr(0); if (n_remain == 0) n_egcshift(); end
        else begin n_srcmask[0] = 0; n_egcshift(); end
      end
    end
  endtask

  task automatic n_w_upl;
    begin
      if (n_stack < (16 - n_dstbit)) n_gate(0);
      else begin
        n_stack -= (16 - n_dstbit);
        n_sub_upl(0);
        if (n_remain != 0) begin n_sub_upl(1); if (n_remain == 0) n_egcshift(); end
        else begin n_srcmask[1] = 0; n_egcshift(); end
      end
    end
  endtask

  task automatic n_w_dnl;
    begin
      if (n_stack < (16 - n_dstbit)) n_gate(0);
      else begin
        n_stack -= (16 - n_dstbit);
        n_sub_dnl(1);
        if (n_remain != 0) begin n_sub_dnl(0); if (n_remain == 0) n_egcshift(); end
        else begin n_srcmask[0] = 0; n_egcshift(); end
      end
    end
  endtask

  task automatic n_call_func;
    begin
      case (n_func)
        0: n_w_upn;
        1: n_w_dnn;
        2: n_w_upr;
        3: n_w_dnr;
        4: n_w_upl;
        default: n_w_dnl;
      endcase
    end
  endtask

  // shiftinput_incw: the WORD feed's stack arithmetic and the feed's value, which the
  // caller has already written at n_inptr (lo) and n_inptr+1 (hi).
  task automatic n_incw(input integer lo, input integer hi);
    begin
      n_inptr = n_inptr + 2;
      if (n_srcbit >= 8) n_outptr = n_outptr + 1;
      n_stack = n_stack + (16 - n_srcbit);
      n_srcbit = 0;
      n_srcmask[0] = 255; n_srcmask[1] = 255;
      n_call_func;
    end
  endtask

  task automatic n_decw(input integer lo, input integer hi);
    begin
      n_inptr = n_inptr - 2;
      if (n_srcbit >= 8) n_outptr = n_outptr - 1;
      n_stack = n_stack + (16 - n_srcbit);
      n_srcbit = 0;
      n_srcmask[0] = 255; n_srcmask[1] = 255;
      n_call_func;
    end
  endtask

  // egc_readword's feed (mem/memegc.c:1200-1230): COMPAREREAD set, SHIFT_CPU clear.
  task automatic n_feed_read(input integer lo, input integer hi);
    begin
      if (!n_sft_d[12]) begin
        nbuf[n_inptr]     = lo[7:0];
        nbuf[n_inptr + 1] = hi[7:0];
        n_incw(lo, hi);
      end else begin
        nbuf[n_inptr - 1] = lo[7:0];
        nbuf[n_inptr]     = hi[7:0];
        n_decw(lo, hi);
      end
    end
  endtask

  // EGCOPE_SHIFTW's feed (mem/memegc.c:653-681): the write value at inptr, then incw/decw.
  task automatic n_feed_write(input integer lo, input integer hi);
    begin
      if (!n_sft_d[12]) begin
        nbuf[n_inptr]     = lo[7:0];
        nbuf[n_inptr + 1] = hi[7:0];
        n_incw(lo, hi);
      end else begin
        nbuf[n_inptr - 1] = lo[7:0];
        nbuf[n_inptr]     = hi[7:0];
        n_decw(lo, hi);
      end
    end
  endtask

  // egcsftb_*0 (mem/memegc.c:372-570): the byte produce's stack gate, its stack spend
  // and the bit-length re-arm around the _sub above. The gate's `(UINT)(8 - egc.dstbit)`
  // wraps negative for dstbit 9..15 (a faithful NP2kai quirk), so a
  // produce there is gated forever and only dstbit == 8 reaches the _sub's early return.
  task automatic n_b0(input integer ext);
    begin
      if ((n_dstbit > 8) || (n_stack < (8 - n_dstbit))) n_srcmask[ext] = 0;
      else begin
        n_stack = n_stack - (8 - n_dstbit);
        case (n_func)
          0: n_sub_upn(ext); 1: n_sub_dnn(ext); 2: n_sub_upr(ext);
          3: n_sub_dnr(ext); 4: n_sub_upl(ext); default: n_sub_dnl(ext);
        endcase
        if (n_remain == 0) n_egcshift;
      end
    end
  endtask

  // EGCOPE_SHIFTB + shiftinput_byte (mem/memegc.c:590-609, :639-648): the byte feed.
  // The value lands at inptr in BOTH directions (the direction moves inptr after), and
  // the produce is one egcsftb_*0 for ext = addr & 1.
  task automatic n_feed_byte(input integer ext, input [7:0] val);
    begin
      nbuf[n_inptr] = val;
      if (n_stack <= 16) begin
        if (n_srcbit >= 8) n_srcbit = n_srcbit - 8;
        else begin n_stack = n_stack + (8 - n_srcbit); n_srcbit = 0; end
        if (!n_sft_d[12]) n_inptr = n_inptr + 1;
        else              n_inptr = n_inptr - 1;
      end
      n_srcmask[ext] = 255;
      n_b0(ext);
    end
  endtask

  // The reference side of one MISALIGNED word: memegc_wr16/rd16 at
  // an ODD address is two byte operations, run HIGH-byte-first when sft bit 12 is set
  // (memegc.c:1379-1413) - so the hi byte (ext 0, at addr+1) feeds first descending.
  task automatic n_feed_odd(input [15:0] val);
    begin
      if (!n_sft_d[12]) begin
        n_feed_byte(1, val[7:0]);
        n_feed_byte(0, val[15:8]);
      end else begin
        n_feed_byte(0, val[15:8]);
        n_feed_byte(1, val[7:0]);
      end
    end
  endtask
  // ==== CHECKS ====
  integer errors = 0;
  integer units_checked = 0;
  integer case_mismatch = 0;
  integer cases_run = 0;
  integer cases_failed = 0;
  integer case_no = 0;

  task automatic fail(input [8*160-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task automatic arm(input [15:0] sft, input [15:0] leng);
    begin
      @(negedge clk);
      reg_sft = sft; reg_leng = leng; reg_shift_we = 1'b1;
      n_sft_d = sft; n_leng_d = leng;
      n_egcshift;
      @(negedge clk);
      reg_shift_we = 1'b0;
    end
  endtask

  // Each case starts from NP2kai's egc_reset(): the whole EGC struct is zeroed (state,
  // the shifter and its 4096-byte buffer), then the arm above runs. Without a per-case
  // reset the RTL's `sreg` and the reference's buffer would both carry the previous
  // case's bytes, and a mismatch there would be the harness's, not the RTL's.
  task automatic reset_case;
    integer b;
    begin
      reset = 1'b1;
      repeat (3) @(posedge clk);
      reset = 1'b0;
      repeat (2) @(posedge clk);
      for (b = 0; b < NBUF; b = b + 1) nbuf[b] = 8'h00;
    end
  endtask

  task automatic cpu_read_word(input [14:0] off, input [1:0] pl, output [15:0] data);
    begin
      @(negedge clk);
      cpu_page = 1'b0; cpu_offset = off; cpu_plane = pl;
      cpu_be = off[1] ? 4'b1100 : 4'b0011; cpu_write = 1'b0; cpu_valid = 1'b1;
      while (!cpu_ready) @(negedge clk);
      // Released at the ready edge (z486's shape, src/z486/bus_unit.sv:348-350 `ext_valid_r <= 1'b0`),
      // before the pipelined produce's response cycle - held into it, the S_IDLE accept
      // takes the request twice. Read values are unchanged (EGCREAD.CSV / the machine vectors).
      // The negedge below is the old release's own wait, kept so the +1 stays in the cadence.
      cpu_valid = 1'b0; cpu_be = 4'b0;
      while (!cpu_resp_valid) @(negedge clk);
      #1 data = off[1] ? cpu_dout[31:16] : cpu_dout[15:0];
      @(negedge clk);
      while (dut.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
    end
  endtask

  task automatic cpu_write_word(input [14:0] off, input [1:0] pl, input [15:0] data);
    begin
      @(negedge clk);
      cpu_page = 1'b0; cpu_offset = off; cpu_plane = pl;
      cpu_din = off[1] ? {data, 16'h0000} : {16'h0000, data};
      cpu_be = off[1] ? 4'b1100 : 4'b0011;
      cpu_write = 1'b1; cpu_valid = 1'b1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'b0;
      while (dut.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
    end
  endtask

  // A MISALIGNED 16-bit access at `off` (off & 3 == 1): ONE cycle with be = 0110, the
  // operand's lo byte at lane 1 and its hi byte at lane 2 (calc_be's word at an odd
  // lane, z486_pkg.sv:1169).
  task automatic cpu_write_odd(input [14:0] off, input [1:0] pl, input [15:0] data);
    begin
      @(negedge clk);
      cpu_page = 1'b0; cpu_offset = off & 15'h7FFC; cpu_plane = pl;
      cpu_din = {8'h00, data, 8'h00};
      cpu_be = 4'b0110;
      cpu_write = 1'b1; cpu_valid = 1'b1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'b0;
      while (dut.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
    end
  endtask

  task automatic cpu_read_odd(input [14:0] off, input [1:0] pl, output [15:0] data);
    begin
      @(negedge clk);
      cpu_page = 1'b0; cpu_offset = off & 15'h7FFC; cpu_plane = pl;
      cpu_be = 4'b0110; cpu_write = 1'b0; cpu_valid = 1'b1;
      while (!cpu_ready) @(negedge clk);
      // Released at the ready edge, before the pipelined produce's response cycle (see cpu_read_word);
      // the negedge below is the old release's own wait, kept so the +1 stays in the cadence.
      cpu_valid = 1'b0; cpu_be = 4'b0;
      while (!cpu_resp_valid) @(negedge clk);
      #1 data = cpu_dout[23:8];
      @(negedge clk);
      while (dut.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
    end
  endtask

  // A single-byte access at `off` (its lane is off[1:0] within the dword, ext = off & 1).
  task automatic cpu_write_byte(input [14:0] off, input [1:0] pl, input [7:0] data);
    begin
      @(negedge clk);
      cpu_page = 1'b0; cpu_offset = off & 15'h7FFC; cpu_plane = pl;
      cpu_din = {24'h0, data} << {off[1:0], 3'b000};
      cpu_be = 4'b0001 << off[1:0];
      cpu_write = 1'b1; cpu_valid = 1'b1;
      while (!cpu_ready) @(negedge clk);
      @(negedge clk);
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'b0;
      while (dut.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
    end
  endtask

  task automatic cpu_read_byte(input [14:0] off, input [1:0] pl, output [7:0] data);
    begin
      @(negedge clk);
      cpu_page = 1'b0; cpu_offset = off & 15'h7FFC; cpu_plane = pl;
      cpu_be = 4'b0001 << off[1:0];
      cpu_write = 1'b0; cpu_valid = 1'b1;
      while (!cpu_ready) @(negedge clk);
      // Released at the ready edge, before the pipelined produce's response cycle (see cpu_read_word);
      // the negedge below is the old release's own wait, kept so the +1 stays in the cadence.
      cpu_valid = 1'b0; cpu_be = 4'b0;
      while (!cpu_resp_valid) @(negedge clk);
      #1 data = cpu_dout[{off[1:0], 3'b000} +: 8];
      @(negedge clk);
      while (dut.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
    end
  endtask

  // Fill every plane's row at `base` with a deterministic, position-dependent pattern.
  task automatic fill_row(input [14:0] base, input integer words);
    integer n;
    begin
      for (n = 0; n < words; n = n + 1) begin
        mem[0][base + 2 * n] = 8'h40 + n[7:0]; mem[0][base + 2 * n + 1] = 8'h80 + 3 * n[7:0];
        mem[1][base + 2 * n] = 8'h40 + n[7:0]; mem[1][base + 2 * n + 1] = 8'h80 + 3 * n[7:0];
        mem[2][base + 2 * n] = 8'h40 + n[7:0]; mem[2][base + 2 * n + 1] = 8'h80 + 3 * n[7:0];
        mem[3][base + 2 * n] = 8'h40 + n[7:0]; mem[3][base + 2 * n + 1] = 8'h80 + 3 * n[7:0];
      end
    end
  endtask

  task automatic clear_row(input [14:0] base, input integer words);
    integer n;
    begin
      for (n = 0; n < words; n = n + 1) begin
        mem[0][base + 2 * n] = 0; mem[0][base + 2 * n + 1] = 0;
        mem[1][base + 2 * n] = 0; mem[1][base + 2 * n + 1] = 0;
        mem[2][base + 2 * n] = 0; mem[2][base + 2 * n + 1] = 0;
        mem[3][base + 2 * n] = 0; mem[3][base + 2 * n + 1] = 0;
      end
    end
  endtask

  task automatic report(input integer bad, input [15:0] sft, input [15:0] leng,
                        input [8*120-1:0] title);
    begin
      cases_run = cases_run + 1;
      if (bad == 0)
        $display("PASS %0s (sft=%04x leng=%04x): 12/12 destination words match NP2kai",
                 title, sft, leng);
      else begin
        cases_failed = cases_failed + 1;
        $display("FAIL %0s (sft=%04x leng=%04x): %0d/12 destination words differ from NP2kai",
                 title, sft, leng, bad);
      end
    end
  endtask

  // One 0x28F0 shake case: read the source row, feed the reference (NP2kai egc_readword's
  // COMPAREREAD feed + egcsftb/egcsftw), write the emitted word, and compare every
  // destination byte to the reference's sdata & srcmask.
  task automatic run_case(input [15:0] sft, input [15:0] leng,
                          input [8*120-1:0] title);
    integer n, bad;
    reg [7:0] wlo, whi;
    reg [15:0] rw, srcw, got, want;
    reg [14:0] dst_base;
    begin
      dst_base = 15'h2000 + case_no * 15'h0020;
      case_no = case_no + 1;
      bad = 0;
      reg_ope = 16'h28F0;        // COMPAREREAD | WS_ROP | ROP 0xF0 (src)
      reset_case;
      arm(sft, leng);
      clear_row(dst_base, 12);
      for (n = 0; n < 12; n = n + 1) begin
        srcw = {mem[0][15'h1000 + 2 * n + 1], mem[0][15'h1000 + 2 * n]};
        cpu_read_word(15'h1000 + 2 * n, 2'd0, rw);
        n_feed_read(srcw[7:0], srcw[15:8]);
        cpu_write_word(dst_base + 2 * n, 2'd0, rw);
        units_checked = units_checked + 1;
        wlo = n_sdata[0] & n_srcmask[0];
        whi = n_sdata[1] & n_srcmask[1];
        want = {whi, wlo};
        got  = {mem[0][dst_base + 2 * n + 1], mem[0][dst_base + 2 * n]};
        if (got !== want) begin
          bad = bad + 1; case_mismatch = case_mismatch + 1;
          $display("MISMATCH %0s: sft=%04x leng=%04x unit %0d src=%04x got=%04x want=%04x (NP2kai sdata=%04x srcmask=%04x)",
                   title, sft, leng, n, srcw, got, want,
                   {n_sdata[1], n_sdata[0]}, {n_srcmask[1], n_srcmask[0]});
        end
      end
      report(bad, sft, leng, title);
    end
  endtask

  // One 0x0CF0 write-feed case: WS_ROP | SHIFT_CPU | ROP 0xF0. NP2kai's EGCOPE_SHIFTW
  // writes the CPU word at inptr and runs shiftinput_incw/decw, so this WRITE both feeds
  // the shifter and stores its output.
  task automatic run_writefeed(input [15:0] sft, input [15:0] leng,
                               input [8*120-1:0] title);
    integer n, bad;
    reg [7:0] wlo, whi;
    reg [15:0] srcw, got, want;
    reg [14:0] dst_base;
    begin
      dst_base = 15'h2000 + case_no * 15'h0020;
      case_no = case_no + 1;
      bad = 0;
      reg_ope = 16'h0CF0;        // WS_ROP | SHIFT_CPU | ROP 0xF0 (src)
      reset_case;
      arm(sft, leng);
      clear_row(dst_base, 12);
      for (n = 0; n < 12; n = n + 1) begin
        srcw = {mem[0][15'h1200 + 2 * n + 1], mem[0][15'h1200 + 2 * n]};
        cpu_write_word(dst_base + 2 * n, 2'd0, srcw);
        n_feed_write(srcw[7:0], srcw[15:8]);
        units_checked = units_checked + 1;
        wlo = n_sdata[0] & n_srcmask[0];
        whi = n_sdata[1] & n_srcmask[1];
        want = {whi, wlo};
        got  = {mem[0][dst_base + 2 * n + 1], mem[0][dst_base + 2 * n]};
        if (got !== want) begin
          bad = bad + 1; case_mismatch = case_mismatch + 1;
          $display("MISMATCH %0s: sft=%04x leng=%04x unit %0d src=%04x got=%04x want=%04x (NP2kai sdata=%04x srcmask=%04x)",
                   title, sft, leng, n, srcw, got, want,
                   {n_sdata[1], n_sdata[0]}, {n_srcmask[1], n_srcmask[0]});
        end
      end
      reg_ope = 16'h28F0;
      report(bad, sft, leng, title);
    end
  endtask

  // One NO-ARM-AFTER-RESET store: NP2kai's egc_reset ends in
  // egcshift() at leng 0x000F (io/egc.c:69-80), so the shifter's first post-reset
  // produce has the FULL 16-dot bit length and masks the first word store 0xFFFF. A
  // guest that stores before its first 0x4AC/0x4AE write (a plain WS_CPU copy) must
  // therefore get a bit-exact store; with the RTL's old reset remain of 1 the first
  // store was masked 0x0080 and 15 of its 16 bits never landed.
  task automatic run_noarm(input [8*120-1:0] title);
    integer n, bad;
    reg [7:0] wlo, whi;
    reg [15:0] srcw, got, want;
    reg [14:0] dst_base;
    begin
      dst_base = 15'h2000 + case_no * 15'h0020;
      case_no = case_no + 1;
      bad = 0;
      reg_ope = 16'h0000;        // WS_CPU: the store is the CPU word through srcmask
      reset_case;
      // The power-up register image (io/egc.c's egc_reset) and the reset arm, modelled
      // WITHOUT the DUT's 0x4AC/0x4AE arm pulse.
      reg_sft = 16'h0000; reg_leng = 16'h000F;
      n_sft_d = 16'h0000; n_leng_d = 16'h000F;
      n_egcshift;
      clear_row(dst_base, 12);
      for (n = 0; n < 12; n = n + 1) begin
        srcw = {mem[0][15'h1200 + 2 * n + 1], mem[0][15'h1200 + 2 * n]};
        cpu_write_word(dst_base + 2 * n, 2'd0, srcw);
        n_feed_write(srcw[7:0], srcw[15:8]);
        units_checked = units_checked + 1;
        wlo = srcw[7:0]  & n_srcmask[0];
        whi = srcw[15:8] & n_srcmask[1];
        want = {whi, wlo};
        got  = {mem[0][dst_base + 2 * n + 1], mem[0][dst_base + 2 * n]};
        if (got !== want) begin
          bad = bad + 1; case_mismatch = case_mismatch + 1;
          $display("MISMATCH %0s: unit %0d src=%04x got=%04x want=%04x (NP2kai sdata=%04x srcmask=%04x)",
                   title, n, srcw, got, want,
                   {n_sdata[1], n_sdata[0]}, {n_srcmask[1], n_srcmask[0]});
        end
      end
      cases_run = cases_run + 1;
      if (bad == 0)
        $display("PASS %0s (sft=0000 leng=000F): 12/12 destination words match NP2kai", title);
      else begin
        cases_failed = cases_failed + 1;
        $display("FAIL %0s (sft=0000 leng=000F): %0d/12 destination words differ from NP2kai",
                 title, bad);
      end
      reg_ope = 16'h28F0;
    end
  endtask

  // One BYTE BLIT: each iteration is a
  // single-byte READ feeding one egcsftb_*0 produce and a single-byte write of the ROP
  // src. A DESCENDING byte produce must read the ring at the FIRST step's position -
  // egcsftb_dnl_sub does outptr-- and THEN reads outptr[1]/outptr[0] (mem/memegc.c:
  // 331-369), i.e. (pre, pre-1), not the second step's slot. All four lanes.
  task automatic run_byte_blit(input [15:0] sft, input [15:0] leng,
                               input [8*120-1:0] title);
    integer k, bad;
    reg [7:0] rb, got8, want8;
    reg [14:0] dst_base;
    begin
      dst_base = 15'h2000 + case_no * 15'h0020;
      case_no = case_no + 1;
      bad = 0;
      reg_ope = 16'h28F0;        // COMPAREREAD | WS_ROP | ROP 0xF0 (src)
      reset_case;
      arm(sft, leng);
      clear_row(dst_base, 12);
      for (k = 0; k < 8; k = k + 1) begin
        cpu_read_byte(15'h1600 + k[14:0], 2'd0, rb);
        // The MODEL is fed the row's own byte: the DUT's return here is NOT the raw plane byte.
        // This case's ope (0x28F0) has bit 13 set, which on the machine is the colour-key COMPARE
        // and only a mask when 0x4A2 names FG/BG (docs/probes/egc-conformance; pc9821_egc.sv's
        // ope_cmprd). With 0x4A2 = 0x00FF (this bench) the return is the shifter's own output,
        // so a model fed from it would shift an already-shifted byte - NP2kai's `mem[addr]` for
        // this bit is what the old feeding assumed.
        n_feed_byte(k & 1, mem[0][15'h1600 + k]);
        cpu_write_byte(dst_base + k[14:0], 2'd0, rb);
        units_checked = units_checked + 1;
        want8 = n_sdata[k & 1] & n_srcmask[k & 1];
        got8  = mem[0][dst_base + k[14:0]];
        if (got8 !== want8) begin
          bad = bad + 1; case_mismatch = case_mismatch + 1;
          $display("MISMATCH %0s: sft=%04x leng=%04x byte %0d (ext %0d) src=%02x got=%02x want=%02x (NP2kai sdata=%02x srcmask=%02x)",
                   title, sft, leng, k, k & 1, rb, got8, want8,
                   n_sdata[k & 1], n_srcmask[k & 1]);
        end
      end
      cases_run = cases_run + 1;
      if (bad == 0)
        $display("PASS %0s (sft=%04x leng=%04x): 8/8 destination bytes match NP2kai",
                 title, sft, leng);
      else begin
        cases_failed = cases_failed + 1;
        $display("FAIL %0s (sft=%04x leng=%04x): %0d/8 destination bytes differ from NP2kai",
                 title, sft, leng, bad);
      end
      reg_ope = 16'h28F0;
    end
  endtask

  // One MISALIGNED-WORD BLIT, the 0x28F0 read-feed form: each
  // iteration is a be = 0110 READ feeding the shifter with memegc_rd16's two byte
  // operations (HIGH-byte-first when descending) followed by a be = 0110 write of the
  // ROP src per byte unit. Six misaligned words per case.
  task automatic run_odd_blit(input [15:0] sft, input [15:0] leng,
                              input [8*120-1:0] title);
    integer k, bad;
    reg [7:0] blo, bhi;
    reg [15:0] srcw, rw, got, want;
    reg [14:0] dst_base, d;
    begin
      dst_base = 15'h2000 + case_no * 15'h0020;
      case_no = case_no + 1;
      bad = 0;
      reg_ope = 16'h28F0;        // COMPAREREAD | WS_ROP | ROP 0xF0 (src)
      reset_case;
      arm(sft, leng);
      clear_row(dst_base, 12);
      for (k = 0; k < 6; k = k + 1) begin
        srcw = {mem[0][15'h1400 + 4 * k + 2], mem[0][15'h1400 + 4 * k + 1]};
        cpu_read_odd(15'h1400 + 4 * k + 1, 2'd0, rw);
        n_feed_odd(srcw);
        d = dst_base + 4 * k + 1;
        cpu_write_odd(d, 2'd0, rw);
        units_checked = units_checked + 2;
        blo = n_sdata[1] & n_srcmask[1];          // the byte at the odd address
        bhi = n_sdata[0] & n_srcmask[0];          // its high neighbour
        want = {bhi, blo};
        got  = {mem[0][d + 1], mem[0][d]};
        if (got !== want) begin
          bad = bad + 1; case_mismatch = case_mismatch + 1;
          $display("MISMATCH %0s: sft=%04x leng=%04x word %0d src=%04x got=%04x want=%04x (NP2kai sdata=%04x srcmask=%04x)",
                   title, sft, leng, k, srcw, got, want,
                   {n_sdata[1], n_sdata[0]}, {n_srcmask[1], n_srcmask[0]});
        end
      end
      cases_run = cases_run + 1;
      if (bad == 0)
        $display("PASS %0s (sft=%04x leng=%04x): 6/6 misaligned words match NP2kai",
                 title, sft, leng);
      else begin
        cases_failed = cases_failed + 1;
        $display("FAIL %0s (sft=%04x leng=%04x): %0d/6 misaligned words differ from NP2kai",
                 title, sft, leng, bad);
      end
      reg_ope = 16'h28F0;
    end
  endtask

  // One MISALIGNED-WORD WRITE FEED, the 0x0CF0 form: each be = 0110
  // store feeds the CPU bytes through memegc_wr16's two byte operations (HIGH-byte-first
  // when descending) and stores the ROP src per byte unit.
  task automatic run_odd_writefeed(input [15:0] sft, input [15:0] leng,
                                   input [8*120-1:0] title);
    integer k, bad;
    reg [7:0] blo, bhi;
    reg [15:0] val, got, want;
    reg [14:0] dst_base, d;
    begin
      dst_base = 15'h2000 + case_no * 15'h0020;
      case_no = case_no + 1;
      bad = 0;
      reg_ope = 16'h0CF0;        // WS_ROP | SHIFT_CPU | ROP 0xF0 (src)
      reset_case;
      arm(sft, leng);
      clear_row(dst_base, 12);
      for (k = 0; k < 6; k = k + 1) begin
        val = {8'hA5 + 8'(3 * k), 8'h5A + 8'(k)};
        d = dst_base + 4 * k + 1;
        cpu_write_odd(d, 2'd0, val);
        n_feed_odd(val);
        units_checked = units_checked + 2;
        blo = n_sdata[1] & n_srcmask[1];
        bhi = n_sdata[0] & n_srcmask[0];
        want = {bhi, blo};
        got  = {mem[0][d + 1], mem[0][d]};
        if (got !== want) begin
          bad = bad + 1; case_mismatch = case_mismatch + 1;
          $display("MISMATCH %0s: sft=%04x leng=%04x word %0d src=%04x got=%04x want=%04x (NP2kai sdata=%04x srcmask=%04x)",
                   title, sft, leng, k, val, got, want,
                   {n_sdata[1], n_sdata[0]}, {n_srcmask[1], n_srcmask[0]});
        end
      end
      cases_run = cases_run + 1;
      if (bad == 0)
        $display("PASS %0s (sft=%04x leng=%04x): 6/6 misaligned words match NP2kai",
                 title, sft, leng);
      else begin
        cases_failed = cases_failed + 1;
        $display("FAIL %0s (sft=%04x leng=%04x): %0d/6 misaligned words differ from NP2kai",
                 title, sft, leng, bad);
      end
      reg_ope = 16'h28F0;
    end
  endtask

  // One STACK-PEAK case (research-res-egc): the shifter bookkeeping was narrowed to a
  // 6-bit stack, whose reachable peak is 32 -- two gated byte feeds climb 0 -> 8 -> 16
  // (dstbit 9 makes the byte produce gate `stack < (8 - dstbit)` wrap huge, so each adds
  // its 8 bits without spending) and a following word feed with srcbit 0 adds 16 at the
  // 16-threshold, so stack_fed reaches 32 exactly. The narrowed width must hold that
  // without wrap; the word's output is compared against the same NP2kai reference (integer
  // stack, so it can never wrap). The arm's leng 0x0FFF also loads remain = 4096, the
  // 13-bit remain peak.
  task automatic run_stack_peak(input [8*120-1:0] title);
    integer bad;
    reg [7:0] blo, bhi;
    reg [15:0] val, got, want;
    reg [14:0] dst_base;
    begin
      dst_base = 15'h2000 + case_no * 15'h0020;
      case_no = case_no + 1;
      bad = 0;
      reg_ope = 16'h0CF0;   // WS_ROP | SHIFT_CPU | ROP 0xF0: both byte and word feeds store the ROP src
      reset_case;
      arm(16'h0090, 16'h0FFF);   // dstbit 9, srcbit 0, remain 4096
      clear_row(dst_base, 12);
      cpu_write_byte(dst_base + 0, 2'd0, 8'hA1); n_feed_byte(0, 8'hA1);
      cpu_write_byte(dst_base + 1, 2'd0, 8'hB2); n_feed_byte(1, 8'hB2);
      // The gated byte produce emits srcmask 0, so its two stores must leave the cleared
      // destination bytes untouched.
      if (mem[0][dst_base + 0] !== 8'h00 || mem[0][dst_base + 1] !== 8'h00) begin
        bad = bad + 1; case_mismatch = case_mismatch + 1;
        $display("MISMATCH %0s: gated byte feed wrote %02x/%02x want 00/00",
                 title, mem[0][dst_base + 0], mem[0][dst_base + 1]);
      end
      val = {8'hC3, 8'hD4};
      cpu_write_word(dst_base + 2, 2'd0, val);
      n_feed_write(val[7:0], val[15:8]);
      units_checked = units_checked + 1;
      blo = n_sdata[0] & n_srcmask[0];
      bhi = n_sdata[1] & n_srcmask[1];
      want = {bhi, blo};
      got  = {mem[0][dst_base + 3], mem[0][dst_base + 2]};
      if (got !== want) begin
        bad = bad + 1; case_mismatch = case_mismatch + 1;
        $display("MISMATCH %0s: word src=%04x got=%04x want=%04x (NP2kai sdata=%04x srcmask=%04x stack=%0d)",
                 title, val, got, want,
                 {n_sdata[1], n_sdata[0]}, {n_srcmask[1], n_srcmask[0]}, n_stack);
      end
      cases_run = cases_run + 1;
      if (bad == 0)
        $display("PASS %0s: stack peak 32 and remain 4096 produce match NP2kai", title);
      else begin
        cases_failed = cases_failed + 1;
        $display("FAIL %0s: %0d mismatches", title, bad);
      end
      reg_ope = 16'h28F0;
    end
  endtask

  initial begin : run
    integer si, li, ci;
    reg [15:0] lengs [0:4];
    reg [15:0] srcs [0:4];
    reg [15:0] dsts [0:4];

    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (2) @(posedge clk);

    // The source rows every case reads; one for the shake feed, one for the write feed,
    // one for the misaligned-word blit, one for the byte blit.
    fill_row(15'h1000, 12);
    fill_row(15'h1200, 12);
    fill_row(15'h1400, 12);
    fill_row(15'h1600, 12);

    // 0x4AE is a dot count, so NP2kai's remain = LOW12(leng) + 1.
    lengs[0] = 16'h000F;   // 16 dots
    lengs[1] = 16'h0007;   // 8 dots
    lengs[2] = 16'h0000;   // 1 dot
    lengs[3] = 16'h0010;   // 17 dots
    lengs[4] = 16'h027F;   // 640 dots
    srcs[0] = 16'h0; srcs[1] = 16'h1; srcs[2] = 16'h2; srcs[3] = 16'h8; srcs[4] = 16'hF;
    dsts[0] = 16'h0; dsts[1] = 16'h1; dsts[2] = 16'h2; dsts[3] = 16'h8; dsts[4] = 16'hF;

    // ============================================================
    $display("== egc_shift section 1: the shift magnitude (sft low nibble 0/8 and the 16-dot length) ==");
    // ============================================================
    // sft = 0x0000 is no sub-byte shift; 0x0008 is the one-byte boundary case that
    // master.lib's egc_shift_left_all(8) writes; 0x0010 moves the destination bit
    // address alone. Each is run across the bit-length register's variants.
    run_case(16'h0000, 16'h000F, "shift 0, 16-dot length");
    run_case(16'h0000, 16'h0007, "shift 0, 8-dot length");
    run_case(16'h0000, 16'h0000, "shift 0, 1-dot length");
    run_case(16'h0000, 16'h0010, "shift 0, 17-dot length");
    run_case(16'h0000, 16'h027F, "shift 0, 640-dot length");
    run_case(16'h0008, 16'h000F, "shift 8 (byte boundary), 16-dot length");
    run_case(16'h0008, 16'h0007, "shift 8 (byte boundary), 8-dot length");
    run_case(16'h0008, 16'h0000, "shift 8 (byte boundary), 1-dot length");
    run_case(16'h0008, 16'h0010, "shift 8 (byte boundary), 17-dot length");
    run_case(16'h0008, 16'h027F, "shift 8 (byte boundary), 640-dot length");
    run_case(16'h0010, 16'h000F, "1-dot shift (src 0, dst 1), 16-dot length");
    run_case(16'h0010, 16'h027F, "1-dot shift (src 0, dst 1), 640 dots");

    // ============================================================
    $display("== egc_shift section 2: the sub-byte sweep (src_bit x dst_bit) ==");
    // ============================================================
    // src_bit and dst_bit each 0..15; the byte-relative parts (bits 2:0) select the
    // NP2kai sub function and the whole-byte part (bit 3) is the pointer offset.
    for (si = 0; si < 5; si = si + 1)
      for (li = 0; li < 5; li = li + 1) begin
        run_case(srcs[si] | (dsts[li] << 4), 16'h000F, "sub-byte sweep, 16-dot length");
        run_case(srcs[si] | (dsts[li] << 4), 16'h027F, "sub-byte sweep, 640-dot length");
      end

    // ============================================================
    $display("== egc_shift section 3: the descending direction (master.lib's or 0x1000) ==");
    // ============================================================
    for (si = 0; si < 5; si = si + 1)
      for (li = 0; li < 5; li = li + 1) begin
        run_case(16'h1000 | srcs[si] | (dsts[li] << 4), 16'h000F, "descending sweep, 16-dot length");
        run_case(16'h1000 | srcs[si] | (dsts[li] << 4), 16'h027F, "descending sweep, 640-dot length");
      end

    // ============================================================
    $display("== egc_shift section 4: master.lib's own forms ==");
    // ============================================================
    // egc_shift_left_all(dots): 0x4AC = dots & 0xF, 0x4AE = 639 - dots, dir = 0.
    for (ci = 0; ci < 5; ci = ci + 1) begin
      integer dots;
      dots = (ci == 0) ? 0 : (ci == 1) ? 1 : (ci == 2) ? 2 : (ci == 3) ? 8 : 15;
      run_case(dots & 16'h000F, 16'h027F - dots, "egc_shift_left_all");
    end
    // egc_shift_left(x1,...): src_bit = x1 & 0xF, dst_bit = (x1 - dots) & 0xF.
    run_case(16'h0002, 16'h0140, "egc_shift_left, x1=0x02 dots=0x02");
    run_case(16'h000E, 16'h0140, "egc_shift_left, dst 0x0E src 0x00");

    // ============================================================
    $display("== egc_shift section 5: the 0x0CF0 write feed (EGCOPE_SHIFTW) ==");
    // ============================================================
    for (li = 0; li < 4; li = li + 1) begin
      run_writefeed(16'h0002, lengs[li], "write feed, src 2 dst 0");
      run_writefeed(16'h1002, lengs[li], "write feed, descending src 2 dst 0");
      run_writefeed(16'h0008, lengs[li], "write feed, src bit 8");
    end

    // ============================================================
    $display("== egc_shift section 6: the no-arm-after-reset store ==");
    // ============================================================
    run_noarm("no-arm-after-reset WS_CPU store");

    // ============================================================
    $display("== egc_shift section 7: the misaligned 16-bit split ==");
    // ============================================================
    // be = 0110 is memegc_wr16/rd16 at an ODD address: two byte operations, run
    // HIGH-byte-first when sft bit 12 is set. Ascending controls and the
    // descending shapes, in both feeding forms.
    run_odd_blit(16'h0002, 16'h000F, "misaligned blit, ascending src 2 dst 0");
    run_odd_blit(16'h000A, 16'h003F, "misaligned blit, ascending srcbit 10");
    run_odd_blit(16'h1002, 16'h000F, "misaligned blit, descending src 2 dst 0");
    run_odd_blit(16'h100A, 16'h003F, "misaligned blit, descending srcbit 10");
    run_odd_writefeed(16'h0002, 16'h000F, "misaligned write feed, ascending src 2 dst 0");
    run_odd_writefeed(16'h000A, 16'h003F, "misaligned write feed, ascending srcbit 10");
    run_odd_writefeed(16'h1002, 16'h000F, "misaligned write feed, descending src 2 dst 0");
    run_odd_writefeed(16'h100A, 16'h003F, "misaligned write feed, descending srcbit 10");
    // The plain byte blit: the same produce path without the odd split, by value.
    run_byte_blit(16'h0002, 16'h000F, "byte blit, ascending src 2 dst 0");
    run_byte_blit(16'h000A, 16'h003F, "byte blit, ascending srcbit 10");
    run_byte_blit(16'h1002, 16'h000F, "byte blit, descending src 2 dst 0");
    run_byte_blit(16'h100A, 16'h003F, "byte blit, descending srcbit 10");

    // ============================================================
    $display("== egc_shift section 8: the narrowed bookkeeping's boundaries (research-res-egc) ==");
    // ============================================================
    // remain = LOW12(leng) + 1 peaks at 4096 (leng 0x0FFF); the 13-bit remain must hold it.
    run_case(16'h0000, 16'h0FFF, "remain max 4096, shift 0");
    run_case(16'h0010, 16'h0FFF, "remain max 4096, 1-dot shift (src 0, dst 1)");
    run_case(16'h1002, 16'h0FFF, "remain max 4096, descending src 2 dst 0");
    // A byte feed at dstbit 9 is gated forever (the wrap), so a run of byte blits climbs
    // the 6-bit stack 0 -> 8 -> 16 -> 24 and gates the feed at the fourth.
    run_byte_blit(16'h0090, 16'h0FFF, "stack-gated byte blit (dstbit 9)");
    // The stack's transient peak: two gated byte feeds (stack 16) then a word feed that
    // adds 16 (stack_fed 32), with remain 4096 loaded by the same arm.
    run_stack_peak("stack peak 32 + remain 4096");

    // ==== VERDICT ====
    $display("NOTE egc_shift: %0d cases, %0d mismatched units of %0d checked, %0d cases with a mismatch",
             cases_run, case_mismatch, units_checked, cases_failed);
    if (errors == 0 && case_mismatch == 0) begin
      $display("TB_PC9821_EGC_SHIFT: PASS");
      $finish;
    end
    else
      $fatal(1, "TB_PC9821_EGC_SHIFT: FAIL (%0d cases of %0d, %0d units)",
             cases_failed, cases_run, case_mismatch);
  end

  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_EGC_SHIFT: TIMEOUT");
  end

endmodule
