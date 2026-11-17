`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_FDC_HANDOFF: the byte and abort handoff from the real pc9821_fdc to the real pc9821_fdd_media (behind the real pc9821_block_share/pc9821_block_io, fed by the real uPD71071 pc9821_dmac at its tightest cadence) loses, duplicates and reorders no byte and misses no abort: an 8-sector DMA READ delivers the image's 8192 bytes in order with one medium `adv` per strobe, an 8-sector DMA WRITE lands its 8192 bytes exactly and nothing else, a PIO READ and a PIO WRITE polling MSR every other cycle move every byte once, a WRITE ended by a terminal count inside a sector completes it with the medium's own bytes (the pad bytes, issued back to back), a DOR reset placed 0 to 4 cycles after a DMA strobe of a READ or a WRITE returns the medium to `ready` within 3 cycles, keeps every byte taken before it in order, writes nothing of the cut-off sector and leaves the next command served, a READ ended by a mid-sector terminal count leaves the next READ served, and a mount of the drive placed 0 to 3 cycles after a strobe of a READ or a WRITE ends the request (the controller answers, its earlier bytes in order), writes no byte to either image, and the next READ returns the new image; a DOR reset in the cycle of a READ's, a WRITE's or a READ ID's media request (issued the cycle after the last command byte) or in any of the four cycles after it returns the medium to `ready` within 3 cycles, moves no byte, writes nothing to the image and leaves the same command served (the unregistered handoff misses the abort in the request's own cycle and the controller hangs); and the handoff's cost is asserted: the DMA READ and WRITE, the PIO READ, the pad-ended WRITE and the raw FORMAT each cost at most one clk_sys per byte handed to the medium over the unregistered handoff and exactly the cycles docs/trade-candidates.md T84 records (55,248, 75,891, 9,526, 5,638 and 34,931 with pc9821_block_io's HPS stream stage and the DMA engine's S_SEL state, against 47,018, 67,644, 9,520, 4,609 and 26,700).
//
// WHERE THE EXPECTED VALUES COME FROM (never from this RTL):
//   * the bytes: the image format's own layout, a raw 2HD body's sector at
//     ((((C*2+H) * 8) + R-1) << 10) (NP2kai diskimage/fd/fdd_xdf.c fdd_read_xdf), and a stream
//     carries each of those bytes exactly once, in order;
//   * a DOR reset (bit 7 0->1) aborts the command and the half-received write buffer is dropped,
//     so the sector is unchanged (NP2kai io/fdc.c fdc_o94 -> fdcstatusreset; writesector never
//     runs), and the controller serves the next command;
//   * a terminal count inside a write sector completes the sector: the bytes past the count keep
//     what the medium held (the core's recorded divergence from NP2kai's stale fdc.buf tail,
//     pc9821_fdc's wx_go note; tb_pc9821_fdd_write's W5 shape);
//   * a mount mid-request: the controller is not left waiting (pc9821_fdd_media's mount-edge
//     abort) and no byte of the old request reaches either image; what the result says is not a
//     contract (pc9821_fdc's media-path note), so only that it arrives is checked;
//   * the DMA cadence is pc9821_dmac's own state walk with an immediate memory accept and a
//     one-cycle read latency (S_IDLE -> S_FIRST -> S_DEV -> S_MEM -> S_FIN for port to memory,
//     S_IDLE -> S_FIRST -> S_MEM -> S_RESP -> S_DEV -> S_FIN for memory to port), the tightest
//     the engine can run; the PIO cadence (a strobe every second cycle) is tighter than
//     pc9821_iobus can issue (S_BYTE, S_REPLY, S_HOLD, S_IDLE).
//
// The cycle counts printed as COST lines (command to interrupt) are the measurement of the
// handoff's guest cost, and they are asserted ($fatal, `cost_check`): each case costs at most one
// clk_sys per byte handed to the medium more than the unregistered handoff did on the same case
// (the bound docs/trade-candidates.md T84 was taken on), and exactly the count T84 records. The
// unregistered counts are this bench's own run on the tree before the handoff was registered;
// define FDC_HANDOFF_MEASURE to print the counts instead of asserting them.
//
// ==== DUT ====
`define IMGMAX 1261568

module tb_pc9821_fdc_handoff;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  localparam integer RAW_BYTES = 1261568;
  reg [7:0] imgA [0:`IMGMAX-1];
  reg [7:0] imgN [0:`IMGMAX-1];
  reg [7:0] expA [0:`IMGMAX-1];

  function automatic [7:0] praw(input integer off);
    praw = (off * 3 + 7) & 8'hFF;
  endfunction
  function automatic [7:0] pnew(input integer off);
    pnew = (off * 5 + 91) & 8'hFF;
  endfunction
  function automatic [7:0] pw(input integer seed, input integer j);
    pw = (j * 13 + seed * 37 + 5) & 8'hFF;
  endfunction
  function automatic integer raw_off(input integer c, input integer h, input integer r);
    raw_off = (((c * 2 + h) * 8) + r - 1) * 1024;
  endfunction

  integer i, j, n, k;

  // ==== the guest's memory behind the DMA's bus-master port ====
  reg  [7:0]  gmem [0:65535];
  wire [31:0] mem_addr, mem_din;
  wire        mem_we, mem_req;
  wire [3:0]  mem_be;
  reg  [31:0] mem_dout = 32'hA5A5A5A5;
  reg         mem_resp_valid = 0;
  wire        mem_ready = mem_req;
  always @(posedge clk) begin
    mem_resp_valid <= 1'b0;
    if (mem_req) begin
      if (!mem_we) begin
        mem_dout <= {4{gmem[mem_addr[15:0]]}};
        mem_resp_valid <= 1'b1;
      end else begin
        gmem[mem_addr[15:0]] <= mem_din[7:0];
      end
    end
  end

  // ==== the real uPD71071 ====
  reg        dsel = 0, dwrite = 0;
  reg  [4:0] didx = 0;
  reg  [7:0] ddin = 0;
  wire [3:0] dack;
  wire       dev_we, dev_stb, dev_tc;
  wire [1:0] dev_ch;
  wire [7:0] dev_dout;
  wire [7:0] fdc_dma_out;
  wire       fdc_drq;

  pc9821_dmac u_dma (
    .clk(clk), .reset(reset),
    .sel(dsel), .write(dwrite), .idx(didx), .din(ddin), .dout(), .dout_comb(),
    .dev_drq({1'b0, fdc_drq, 2'b00}), .dev_dack(dack), .dev_we(dev_we), .dev_stb(dev_stb),
    .dev_tc(dev_tc), .dev_ch(dev_ch), .dev_dout(dev_dout), .dev_din(fdc_dma_out),
    .mem_addr(mem_addr), .mem_we(mem_we), .mem_be(mem_be), .mem_din(mem_din),
    .mem_dout(mem_dout), .mem_req(mem_req),
    .mem_ready(mem_ready), .mem_resp_valid(mem_resp_valid), .mem_tc()
  );
  wire ch2_stb = dev_stb && (dev_ch == 2'd2);

  // ==== the real controller, medium and shared adapter ====
  reg        cs = 0, wr = 0, rd = 0;
  reg  [2:0] addr = 0;
  reg  [7:0] din = 0;
  wire [7:0] dout;
  wire       irq;

  wire [1:0]  fdd_present, fdd_wp;
  wire        fdd_req, fdd_req_hdr, fdd_adv, fdd_req_wr, fdd_abort;
  wire [1:0]  fdd_unit;
  wire [7:0]  fdd_c, fdd_h, fdd_r, fdd_n, fdd_idx, fdd_din, fdd_tc;
  wire        fdd_hd, fdd_mf, fdd_2hd, fdd_rpm;
  wire        fdd_ready, fdd_rdy, fdd_hdrv, fdd_err;
  wire [7:0]  fdd_dout, fdd_hr, fdd_hn, fdd_hs;

  pc9821_fdc fdc (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr),
      .win_2dd(1'b0), .strap_2hd(),
      .wr(wr), .rd(rd), .din(din), .dout(dout), .irq(irq), .res_done(),
      .media_present({2'b00, fdd_present}), .writeprotect({2'b00, fdd_wp}),
      .media_chg(4'd0), .frame_tick(1'b0),
      .media_req(fdd_req), .media_req_hdr(fdd_req_hdr), .media_unit(fdd_unit),
      .media_c(fdd_c), .media_h(fdd_h), .media_tc(fdd_tc), .media_hd(fdd_hd), .media_mf(fdd_mf), .media_2hd(fdd_2hd), .media_rpm(fdd_rpm), .media_r(fdd_r), .media_n(fdd_n),
      .media_idx(fdd_idx), .media_wr(fdd_req_wr), .media_din(fdd_din), .media_abort(fdd_abort),
      .media_ready(fdd_ready), .media_rdy(fdd_rdy), .media_hdrv(fdd_hdrv),
      .media_err(fdd_err), .media_dout(fdd_dout),
      .media_hr(fdd_hr), .media_hn(fdd_hn), .media_hs(fdd_hs),
      .media_adv(fdd_adv),
      .dma_drq(fdc_drq), .dma_dack(dack[2]), .dma_stb(ch2_stb),
      .dma_tc(dev_tc && (dev_ch == 2'd2)), .dma_dout(fdc_dma_out),
      .dma_we(dev_we), .dma_din(dev_dout),
      .dbg_state(), .dbg_cmd(), .dbg_result(), .dbg_chrn()
  );

  reg        mnt0 = 0;
  reg [63:0] img_size = 0;

  wire        blk_rd, blk_wr, blk_busy, blk_done, blk_error, blk_slot;
  wire [15:0] blk_lba;
  wire        blk_fill_we;
  wire [ 7:0] blk_fill_addr, blk_rd_addr;
  wire [15:0] blk_fill_data, blk_rd_data;

  pc9821_fdd_media media (
      .clk(clk), .reset(reset),
      .img_mounted(mnt0), .img_size(img_size), .img_readonly(1'b0),
      .img1_mounted(1'b0), .img1_size(64'd0),
      .blk_req_rd(blk_rd), .blk_req_lba(blk_lba), .blk_slot(blk_slot),
      .blk_done(blk_done), .blk_err(blk_error), .blk_busy(blk_busy),
      .blk_fill_we(blk_fill_we), .blk_fill_addr(blk_fill_addr),
      .blk_fill_data(blk_fill_data),
      .blk_req_wr(blk_wr), .blk_rd_addr(blk_rd_addr), .blk_rd_data(blk_rd_data),
      .present(fdd_present), .writeprotect(fdd_wp), .chg(),
      .req(fdd_req), .req_hdr(fdd_req_hdr), .req_wr(fdd_req_wr), .unit(fdd_unit),
      .req_c(fdd_c), .req_h(fdd_h), .req_tc(fdd_tc), .req_hd(fdd_hd), .req_mf(fdd_mf), .req_2hd(fdd_2hd), .req_rpm(fdd_rpm), .req_r(fdd_r), .req_n(fdd_n), .req_idx(fdd_idx),
      .ready(fdd_ready), .rdy(fdd_rdy), .hdrv(fdd_hdrv), .err(fdd_err),
      .dout(fdd_dout), .adv(fdd_adv), .din(fdd_din), .abort(fdd_abort),
      .hdr_r(fdd_hr), .hdr_n(fdd_hn), .hdr_sects(fdd_hs)
  );

  reg        sd_ack_b = 0, sd_buff_wr = 0;
  reg [12:0] sd_buff_addr = 0;
  reg [15:0] sd_buff_dout = 0;
  wire [31:0] sd_lba_a, sd_lba_b, sd_lba_c;
  wire [ 5:0] sd_blk_cnt_a, sd_blk_cnt_b, sd_blk_cnt_c;
  wire        sd_rd_a, sd_wr_a, sd_rd_b, sd_wr_b, sd_rd_c, sd_wr_c;
  wire [15:0] sd_buff_din_a, sd_buff_din_b, sd_buff_din_c;

  pc9821_block_share share (
      .clk(clk), .rst_n(!reset),
      .a_img_mounted(1'b0), .a_img_readonly(1'b0), .a_img_size(64'd0),
      .a_mounted(), .a_readonly(), .a_capacity(),
      .a_req_read(1'b0), .a_req_write(1'b0), .a_req_lba(32'd0),
      .a_req_done(), .a_req_error(), .a_busy(),
      .a_buf_we(), .a_buf_addr(), .a_buf_data(),
      .a_buf_rd_addr(), .a_buf_rd_data(16'd0),
      .a_sd_lba(sd_lba_a), .a_sd_blk_cnt(sd_blk_cnt_a), .a_sd_rd(sd_rd_a), .a_sd_wr(sd_wr_a),
      .a_sd_ack(1'b0), .a_sd_buff_din(sd_buff_din_a),
      .b_img_mounted(mnt0), .b_img_readonly(1'b0), .b_img_size(img_size),
      .b_req_read(blk_rd), .b_req_write(blk_wr), .b_req_lba(blk_lba), .b_req_slot(blk_slot),
      .b_req_done(blk_done), .b_req_error(blk_error), .b_busy(blk_busy),
      .b_buf_we(blk_fill_we), .b_buf_addr(blk_fill_addr), .b_buf_data(blk_fill_data),
      .b_buf_rd_addr(blk_rd_addr), .b_buf_rd_data(blk_rd_data),
      .b_sd_lba(sd_lba_b), .b_sd_blk_cnt(sd_blk_cnt_b),
      .b_sd_rd(sd_rd_b), .b_sd_wr(sd_wr_b),
      .b_sd_ack(sd_ack_b), .b_sd_buff_din(sd_buff_din_b),
      .c_img_mounted(1'b0), .c_img_readonly(1'b0), .c_img_size(64'd0),
      .c_sd_lba(sd_lba_c), .c_sd_blk_cnt(sd_blk_cnt_c),
      .c_sd_rd(sd_rd_c), .c_sd_wr(sd_wr_c),
      .c_sd_ack(1'b0), .c_sd_buff_din(sd_buff_din_c),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
      .dbg_hps_cycles()
  );

  // ==== the host channel (slot B only): tb_pc9821_fdd_write's model ====
  // A read streams (sd_blk_cnt+1)*256 words in at one per clock; a write reads 256 words out of
  // sd_buff_din two clocks after the address moves. `b_is_new` picks the image the slot holds.
  reg        b_is_new = 0;
  integer    hw_a = 0, hw_n = 0;
  reg [12:0] widx, wtotal;
  reg [15:0] hword_q;
  reg [31:0] hlba;
  reg        hbusy = 0, hlast = 0, hwrite = 0;
  reg  [1:0] hph = 0;
  always @(posedge clk) begin
    if (reset) begin
      sd_ack_b <= 1'b0; sd_buff_wr <= 1'b0; hbusy <= 1'b0; hlast <= 1'b0;
      widx <= 13'd0; hwrite <= 1'b0; hph <= 2'd0;
    end else if (!hbusy) begin
      sd_buff_wr <= 1'b0;
      if (sd_rd_b || sd_wr_b) begin
        hbusy <= 1'b1; sd_ack_b <= 1'b1; hwrite <= sd_wr_b; hlba <= sd_lba_b;
        wtotal <= ({7'd0, sd_blk_cnt_b} + 13'd1) * 13'd256 - 13'd1;
        widx <= 13'd0; hph <= 2'd0; sd_buff_addr <= 13'd0;
        if (sd_wr_b) begin
          if (b_is_new) hw_n = hw_n + 1; else hw_a = hw_a + 1;
        end
      end
    end else if (hwrite) begin
      sd_buff_wr <= 1'b0;
      if (hlast) begin
        hbusy <= 1'b0; sd_ack_b <= 1'b0; hlast <= 1'b0;
      end else if (hph == 2'd0) begin
        sd_buff_addr <= widx; hph <= 2'd1;
      end else if (hph == 2'd1) begin
        hph <= 2'd2;
      end else begin
        if (b_is_new) begin
          imgN[hlba * 512 + widx * 2] = sd_buff_din_b[7:0];
          imgN[hlba * 512 + widx * 2 + 1] = sd_buff_din_b[15:8];
        end else begin
          imgA[hlba * 512 + widx * 2] = sd_buff_din_b[7:0];
          imgA[hlba * 512 + widx * 2 + 1] = sd_buff_din_b[15:8];
        end
        hph <= 2'd0;
        if (widx == 13'd255) hlast <= 1'b1;
        else widx <= widx + 13'd1;
      end
    end else begin
      sd_buff_wr   <= 1'b1;
      sd_buff_addr <= widx;
      j = (hlba + {19'd0, widx[12:8]}) * 512 + widx[7:0] * 2;
      hword_q = b_is_new ? {imgN[j + 1], imgN[j]} : {imgA[j + 1], imgA[j]};
      sd_buff_dout <= hword_q;
      if (hlast) begin
        hbusy <= 1'b0; sd_ack_b <= 1'b0; sd_buff_wr <= 1'b0; hlast <= 1'b0;
      end else if (widx == wtotal) begin
        hlast <= 1'b1;
      end else begin
        widx <= widx + 13'd1;
      end
    end
  end

  // ==== the byte ledger: every byte the DMA takes from the port, and every medium `adv` ====
  reg  [7:0] rec [0:16383];
  integer    nrec = 0, nadv = 0, nstb = 0;
  // T84's measured costs (command to interrupt, or to the result phase for the PIO READ), on the
  // unregistered tree (_BASE) and with the registered handoff; docs/trade-candidates.md T84. The
  // registered counts include pc9821_block_io's HPS stream stage (one clk_sys more on each block
  // handshake's acknowledge and completion): 47,033 / 67,660 / 9,520 / 5,334 / 34,892 before it.
  // The unregistered counts were measured before the stage and before the handoff was registered.
  // The stage's cycles (_HPS) are derived from its mechanism, not read off this bench: the engine
  // sees each host block handshake's acknowledge fall one clk_sys later, so the next request and
  // every later handshake of the case move by one. Counted per case over its command-to-interrupt
  // window (each host acknowledge paired with its own with the stage reverted): H1 23 handshakes
  // (23 reads) x 1; H2 39 (23 reads, 16 write-backs) x 1; H5 4 (2 + 2) x 1; H11 39 (23 + 16) x 1;
  // H3, the PIO READ polling MSR every other cycle, 5 handshakes that move 0, 2, 2, 1, 1 (a request
  // one cycle later is seen at the next poll), 6. The handshakes are the medium's block fetches and
  // write-backs, the same with either handoff, so each base carries the same cycles, and the bound
  // below is T84's as stated: at most one clk_sys per byte over base + _HPS.
  localparam integer COST_H1_HPS  = 23 * 1, COST_H2_HPS = (23 + 16) * 1, COST_H3_HPS = 0 + 2 + 2 + 1 + 1;
  localparam integer COST_H5_HPS  = (2 + 2) * 1, COST_H11_HPS = (23 + 16) * 1;
  // The DMA engine's S_SEL state (docs/trade-candidates.md T89) adds one clk_sys to every DMA byte
  // (_DMA): each byte in a case's window costs one more, the DMA bytes being the uPD71071's strobes
  // there - H1 8,192 (8 x 1024 read), H2 8,192 (8 x 1024 written), H5 300 (the count-ended write;
  // its pad bytes are the medium's, no DMA), H3 and H11 none (PIO, and FORMAT's filler). The engine
  // is the same for either handoff, so each base carries the same cycles.
  localparam integer COST_H1_DMA = 8192 * 1, COST_H2_DMA = 8192 * 1, COST_H3_DMA = 0;
  localparam integer COST_H5_DMA = 300 * 1,  COST_H11_DMA = 0;
  localparam integer COST_H1_BASE  = 47018 + COST_H1_HPS + COST_H1_DMA,  COST_H1  = 47056 + COST_H1_DMA;
  localparam integer COST_H2_BASE  = 67644 + COST_H2_HPS + COST_H2_DMA,  COST_H2  = 67699 + COST_H2_DMA;
  localparam integer COST_H3_BASE  = 9520  + COST_H3_HPS + COST_H3_DMA,  COST_H3  = 9526  + COST_H3_DMA;
  localparam integer COST_H5_BASE  = 4609  + COST_H5_HPS + COST_H5_DMA,  COST_H5  = 5338  + COST_H5_DMA;
  localparam integer COST_H11_BASE = 26700 + COST_H11_HPS + COST_H11_DMA, COST_H11 = 34931 + COST_H11_DMA;
  always @(posedge clk) begin
    if (ch2_stb) begin
      nstb = nstb + 1;
      if (!dev_we) begin
        if (nrec < 16384) rec[nrec] = fdc_dma_out;
        nrec = nrec + 1;
      end
    end
    if (fdd_adv) nadv = nadv + 1;
  end
  task automatic ledger_clear;
    begin @(negedge clk); nrec = 0; nadv = 0; nstb = 0; end
  endtask

  // ==== CHECKS ====
  integer fails = 0;
  initial begin
    #900_000_000;
    $fatal(1, "TB_PC9821_FDC_HANDOFF: watchdog timeout (no verdict reached)");
  end
  task automatic expect8(input [7:0] got, input [7:0] want, input [8*100-1:0] what);
    begin
      if (got !== want) begin
        $display("  FAIL: %0s: got %02x, expected %02x", what, got, want);
        fails = fails + 1;
      end
    end
  endtask
  task automatic expecti(input integer got, input integer want, input [8*100-1:0] what);
    begin
      if (got !== want) begin
        $display("  FAIL: %0s: got %0d, expected %0d", what, got, want);
        fails = fails + 1;
      end
    end
  endtask
  task automatic cmp_raw(input [8*80-1:0] what);
    integer bad;
    begin
      bad = 0;
      for (i = 0; i < RAW_BYTES; i = i + 1)
        if (imgA[i] !== expA[i]) begin
          if (bad < 4) $display("  FAIL: %0s: image byte %0d is %02x, expected %02x",
                                what, i, imgA[i], expA[i]);
          bad = bad + 1;
        end
      if (bad != 0) fails = fails + 1;
    end
  endtask
  task automatic cmp_new(input [8*80-1:0] what);
    integer bad;
    begin
      bad = 0;
      for (i = 0; i < RAW_BYTES; i = i + 1)
        if (imgN[i] !== pnew(i)) begin
          if (bad < 4) $display("  FAIL: %0s: new image byte %0d is %02x, it held %02x",
                                what, i, imgN[i], pnew(i));
          bad = bad + 1;
        end
      if (bad != 0) fails = fails + 1;
    end
  endtask
  // the recorded stream against the image from `off`, `cnt` bytes
  task automatic cmp_rec(input integer off, input integer cnt, input newimg,
                         input [8*80-1:0] what);
    integer bad;
    begin
      bad = 0;
      for (i = 0; i < cnt; i = i + 1)
        if (rec[i] !== (newimg ? pnew(off + i) : expA[off + i])) begin
          if (bad < 4) $display("  FAIL: %0s: stream byte %0d is %02x, expected %02x",
                                what, i, rec[i], newimg ? pnew(off + i) : expA[off + i]);
          bad = bad + 1;
        end
      if (bad != 0) fails = fails + 1;
    end
  endtask

  // ==== port helpers (the iobus S_BYTE contract: a one-cycle strobe) ====
  task automatic wr8(input [2:0] a, input [7:0] d);
    begin @(negedge clk); cs = 1; addr = a; wr = 1; rd = 0; din = d;
          @(posedge clk); @(negedge clk); cs = 0; wr = 0; end
  endtask
  reg [7:0] rd_val;
  task automatic rd8(input [2:0] a);
    begin @(negedge clk); cs = 1; addr = a; wr = 0; rd = 1; #1 rd_val = dout;
          @(posedge clk); @(negedge clk); cs = 0; rd = 0; end
  endtask
  task automatic dma_wr(input [4:0] ix, input [7:0] d);
    begin @(negedge clk); dsel = 1; dwrite = 1; didx = ix; ddin = d;
          @(negedge clk); dsel = 0; dwrite = 0; end
  endtask
  // channel 2 as the BIOS programs it: mask, clear the flip-flop, mode, address, count (n - 1),
  // bank, unmask (ports 0x15 / 0x19 / 0x17 / 0x09 / 0x0B / 0x23 / 0x15).
  task automatic dma_prog(input [7:0] mode, input [15:0] a, input [15:0] cnt);
    reg [15:0] nm1;
    begin
      dma_wr(5'd10, 8'h06);
      dma_wr(5'd12, 8'h00);
      dma_wr(5'd11, mode);
      dma_wr(5'd4, a[7:0]); dma_wr(5'd4, a[15:8]);
      nm1 = cnt - 16'd1; dma_wr(5'd5, nm1[7:0]); dma_wr(5'd5, nm1[15:8]);
      dma_wr(5'd17, 8'h00);
      dma_wr(5'd10, 8'h02);
    end
  endtask
  task automatic dma_stop;
    begin dma_wr(5'd10, 8'h06); end
  endtask

  reg [7:0] rs [0:7];
  integer rlen;
  task automatic get_result;
    begin
      rlen = 0;
      for (i = 0; i < 8; i = i + 1) rs[i] = 8'hFF;
      rd8(3'd0);
      while (((rd_val & 8'h40) != 0) && (rlen < 8)) begin
        rd8(3'd1); rs[rlen] = rd_val; rlen = rlen + 1; rd8(3'd0);
      end
    end
  endtask
  task automatic wait_irq(input integer maxc, input [8*60-1:0] what);
    begin
      n = 0;
      while (!irq && n < maxc) begin @(negedge clk); n = n + 1; end
      if (!irq) begin
        $display("  FAIL: %0s: the interrupt never came (the controller hung)", what);
        fails = fails + 1;
      end
    end
  endtask
  task automatic seek_to(input [7:0] c);
    begin
      if (fdc.treg[0] != c) begin
        wr8(3'd1, 8'h0F); wr8(3'd1, 8'h00); wr8(3'd1, c);
        wait_irq(200000, "seek");
        wr8(3'd1, 8'h08); get_result;
      end
    end
  endtask
  // opcode, us|hd<<2, C, H, R, N, EOT, GPL, DTL; t_cmd = the cycle the last byte is written
  integer cyc = 0, t_cmd = 0;
  always @(posedge clk) cyc <= cyc + 1;
  task automatic data_cmd(input [7:0] op, input [7:0] c, input [7:0] r, input [7:0] eot);
    begin
      seek_to(c);
      wr8(3'd1, op);
      wr8(3'd1, 8'h00); wr8(3'd1, c); wr8(3'd1, 8'h00); wr8(3'd1, r);
      wr8(3'd1, 8'h03); wr8(3'd1, eot); wr8(3'd1, 8'h1B); wr8(3'd1, 8'hFF);
      t_cmd = cyc;
    end
  endtask
  task automatic fdc_specify(input nd);
    begin wr8(3'd1, 8'h03); wr8(3'd1, 8'hDF); wr8(3'd1, {7'd0, nd}); end
  endtask
  task automatic mount0(input newimg);
    begin
      img_size = RAW_BYTES;
      @(negedge clk); mnt0 = 1; b_is_new = newimg;
      @(posedge clk); @(negedge clk); mnt0 = 0;
      repeat (6000) @(negedge clk);
    end
  endtask
  // THE DOR RESET (fdc_o94's 0->1 edge of bit 7), placed `off` cycles after the strobe that
  // carries stream byte `at`: the write is presented in the cycle `off` after that strobe's.
  task automatic dor_reset_at(input integer at, input integer off);
    begin
      n = 0;
      while (!(ch2_stb && (nstb == at)) && n < 2000000) begin @(negedge clk); n = n + 1; end
      for (k = 0; k < off; k = k + 1) @(negedge clk);
      cs = 1; addr = 3'd2; wr = 1; rd = 0; din = 8'h80;
      @(posedge clk); @(negedge clk); cs = 0; wr = 0;
      // the medium must be back in `ready` within 3 cycles: the abort reached it
      n = 0;
      while (!fdd_ready && n < 3) begin @(negedge clk); n = n + 1; end
      if (!fdd_ready) begin
        $display("  FAIL: DOR reset %0d cycles after strobe %0d: the medium never left the request (a missed abort)", off, at);
        fails = fails + 1;
      end
      wr8(3'd2, 8'h00);
    end
  endtask
  task automatic mount_at(input integer at, input integer off, input newimg);
    begin
      n = 0;
      while (!(ch2_stb && (nstb == at)) && n < 2000000) begin @(negedge clk); n = n + 1; end
      for (k = 0; k < off; k = k + 1) @(negedge clk);
      img_size = RAW_BYTES; mnt0 = 1; b_is_new = newimg;
      @(posedge clk); @(negedge clk); mnt0 = 0;
    end
  endtask

  // ==== the media-request / DOR-reset monitor (cycle stamps as `cyc` reads at the posedge) ====
  integer nreq = 0, t_req = 0, t_dor = 0;
  always @(posedge clk) begin
    if (fdd_req) begin nreq = nreq + 1; t_req = cyc; end
    if (cs && wr && (addr == 3'd2) && din[7]) t_dor = cyc;
  end

  // A command whose media request is the target: READ (0x46) and WRITE (0x45) of C/R, or READ ID
  // (0x4A) of the drive's track. `t_cmd` is the cycle after the last command byte.
  task automatic req_cmd(input integer kind, input [7:0] c, input [7:0] r);
    begin
      if (kind == 2) begin
        seek_to(c);
        wr8(3'd1, 8'h4A); wr8(3'd1, 8'h00);
        t_cmd = cyc;
      end
      else data_cmd((kind == 1) ? 8'h45 : 8'h46, c, r, r);
    end
  endtask
  // THE DOR RESET ON THE MEDIA REQUEST: the reset is presented in the cycle `dreq + off` after the
  // last command byte, where `dreq` is the request's own delay measured on an undisturbed run of
  // the same command, so off = 0 is the request's own cycle and 1..4 the cycles after it (the
  // stamps are checked: the reset lands exactly `off` cycles after the one request).
  task automatic dor_reset_req(input integer dreq, input integer off, input [8*40-1:0] what);
    begin
      nreq = 0;
      while (cyc < t_cmd + dreq + off) @(negedge clk);
      cs = 1; addr = 3'd2; wr = 1; rd = 0; din = 8'h80;
      @(posedge clk); @(negedge clk); cs = 0; wr = 0;
      n = 0;
      while (!fdd_ready && n < 3) begin @(negedge clk); n = n + 1; end
      if (!fdd_ready) begin
        $display("  FAIL: %0s off %0d: the medium never left the request (a missed abort)", what, off);
        fails = fails + 1;
      end
      wr8(3'd2, 8'h00);
      repeat (2000) @(negedge clk);
      if (nreq != 1 || (t_dor - t_req) != off) begin
        $display("  FAIL: %0s off %0d: %0d requests, the reset %0d cycles after it (placement drifted)",
                 what, off, nreq, t_dor - t_req);
        fails = fails + 1;
      end
    end
  endtask

  // THE T84 COST BOUND (docs/trade-candidates.md T84, the registered handoff's trade): against the
  // unregistered handoff's cycles for the same case (`base`, measured by this bench on the tree
  // before the handoff was registered), the registered one may cost at most one clk_sys per
  // handshake event (`events`: each byte handed to the medium), and it costs exactly what T84
  // records (`want`), so a change to the handoff's cost cannot pass without the trade's numbers
  // moving with it.
  task automatic cost_check(input [8*8-1:0] name, input integer got, input integer base,
                            input integer want, input integer events);
    begin
`ifdef FDC_HANDOFF_MEASURE
      $display("MEASURE %0s %0d", name, got);
`else
      if (got - base > events)
        $fatal(1, "TB_PC9821_FDC_HANDOFF: FAIL %0s costs %0d cycles, %0d over the unregistered %0d: more than one clk_sys per handshake event (%0d)",
               name, got, got - base, base, events);
      if (got != want)
        $fatal(1, "TB_PC9821_FDC_HANDOFF: FAIL %0s costs %0d cycles, docs/trade-candidates.md T84 records %0d",
               name, got, want);
`endif
    end
  endtask

  integer t0, ha0, hn0, nb, off, dreq, tcost;
  reg [7:0] msr;

  // ==== STIMULUS ====
  initial begin
    for (i = 0; i < RAW_BYTES; i = i + 1) begin
      imgA[i] = praw(i); expA[i] = praw(i); imgN[i] = pnew(i);
    end
    for (i = 0; i < 65536; i = i + 1) gmem[i] = (i * 7 + 3) & 8'hFF;

    reset = 1; repeat (6) @(negedge clk);
    reset = 0; repeat (4) @(negedge clk);
    mount0(1'b0);
    expecti(fdd_present[0], 1, "setup: drive 0 present");
    fdc_specify(1'b0);

    // ---- H1: an 8-sector DMA READ, C1 R1..R8, the count ending with the last byte ----
    ledger_clear;
    dma_prog(8'h46, 16'h8000, 16'd8192);
    data_cmd(8'h46, 8'h01, 8'h01, 8'h08);
    wait_irq(4000000, "H1");
    tcost = cyc - t_cmd;
    $display("COST H1 DMA READ 8x1024: %0d cycles from the command to the interrupt", tcost);
    get_result;
    expect8(rs[0], 8'h00, "H1 ST0");
    expecti(nrec, 8192, "H1 bytes the DMA took");
    expecti(nadv, 8192, "H1 medium advances: one per byte");
    cost_check("H1", tcost, COST_H1_BASE, COST_H1, nadv);
    cmp_rec(raw_off(1, 0, 1), 8192, 1'b0, "H1 the stream is the image's C1 R1..R8 in order");
    n = 0;
    for (j = 0; j < 8192; j = j + 1) if (gmem[16'h8000 + j] !== expA[raw_off(1, 0, 1) + j]) n = n + 1;
    expecti(n, 0, "H1 memory holds the image's bytes");

    // ---- H2: an 8-sector DMA WRITE, C2 R1..R8 ----
    for (j = 0; j < 8192; j = j + 1) gmem[j] = pw(2, j);
    ledger_clear; ha0 = hw_a;
    dma_prog(8'h4A, 16'h0000, 16'd8192);
    data_cmd(8'h45, 8'h02, 8'h01, 8'h08);
    wait_irq(4000000, "H2");
    tcost = cyc - t_cmd;
    $display("COST H2 DMA WRITE 8x1024: %0d cycles from the command to the interrupt", tcost);
    get_result;
    expect8(rs[0], 8'h00, "H2 ST0");
    expecti(nstb, 8192, "H2 bytes the DMA gave");
    expecti(nadv, 8192, "H2 medium advances: one per byte");
    cost_check("H2", tcost, COST_H2_BASE, COST_H2, nadv);
    for (j = 0; j < 8192; j = j + 1) expA[raw_off(2, 0, 1) + j] = pw(2, j);
    cmp_raw("H2 the image holds exactly the 8 written sectors");

    // ---- H3: a PIO READ (SPECIFY ND), MSR polled every other cycle, C3 R1..R2 ----
    fdc_specify(1'b1);
    nb = 0; nadv = 0;
    data_cmd(8'h46, 8'h03, 8'h01, 8'h02);
    n = 0;
    begin : h3_loop
      while (n < 4000000) begin
        rd8(3'd0); msr = rd_val; n = n + 1;
        if ((msr & 8'hE0) == 8'hE0) begin
          rd8(3'd1);
          if (nb < 16384) rec[nb] = rd_val;
          nb = nb + 1;
        end else if ((msr & 8'hE0) == 8'hC0) disable h3_loop;
      end
    end
    tcost = cyc - t_cmd;
    $display("COST H3 PIO READ 2x1024: %0d cycles from the command to the result phase", tcost);
    get_result;
    expecti(nb, 2048, "H3 bytes the PIO reader took");
    expecti(nadv, 2048, "H3 medium advances: one per byte");
    cost_check("H3", tcost, COST_H3_BASE, COST_H3, nadv);
    cmp_rec(raw_off(3, 0, 1), 2048, 1'b0, "H3 the PIO stream is C3 R1..R2 in order");
    expect8(rs[1], 8'h80, "H3 ST1 EN (EOT reached with no terminal count)");

    // ---- H4: a PIO WRITE, MSR polled every other cycle, C4 R1..R2 ----
    nb = 0; nadv = 0;
    data_cmd(8'h45, 8'h04, 8'h01, 8'h02);
    n = 0;
    begin : h4_loop
      while (n < 4000000) begin
        rd8(3'd0); msr = rd_val; n = n + 1;
        if (((msr & 8'hF0) == 8'hB0) && (nb < 2048)) begin
          wr8(3'd1, pw(4, nb)); nb = nb + 1;
        end else if ((msr & 8'hC0) == 8'hC0) disable h4_loop;
      end
    end
    get_result;
    expect8(rs[0], 8'h00, "H4 ST0");
    expecti(nb, 2048, "H4 bytes the PIO writer gave");
    expecti(nadv, 2048, "H4 medium advances: one per byte");
    for (j = 0; j < 2048; j = j + 1) expA[raw_off(4, 0, 1) + j] = pw(4, j);
    cmp_raw("H4 the image holds exactly the 2 PIO-written sectors");
    fdc_specify(1'b0);

    // ---- H5: a DMA WRITE ended by its count after 300 bytes of a 1024-byte sector ----
    // The rest of the sector is the pad: 724 bytes back to back, each the medium's own byte.
    for (j = 0; j < 300; j = j + 1) gmem[j] = pw(5, j);
    ledger_clear;
    dma_prog(8'h4A, 16'h0000, 16'd300);
    data_cmd(8'h45, 8'h05, 8'h03, 8'h08);
    wait_irq(4000000, "H5");
    tcost = cyc - t_cmd;
    $display("COST H5 DMA WRITE 300 bytes + 724 pad bytes: %0d cycles from the command to the interrupt", tcost);
    get_result;
    expect8(rs[0], 8'h00, "H5 ST0");
    expecti(nstb, 300, "H5 bytes the DMA gave");
    expecti(nadv, 1024, "H5 medium advances: the 300 bytes and the 724 pad bytes");
    cost_check("H5", tcost, COST_H5_BASE, COST_H5, nadv);
    for (j = 0; j < 300; j = j + 1) expA[raw_off(5, 0, 3) + j] = pw(5, j);
    cmp_raw("H5 the sector holds the 300 bytes, then its own bytes (no pad byte duplicated)");

    // ---- H6: a DMA READ ended by its count inside a sector, then the next READ ----
    ledger_clear;
    dma_prog(8'h46, 16'h8000, 16'd300);
    data_cmd(8'h46, 8'h06, 8'h02, 8'h08);
    wait_irq(4000000, "H6a");
    get_result;
    expect8(rs[0], 8'h00, "H6a ST0");
    expecti(nrec, 300, "H6a 300 bytes");
    cmp_rec(raw_off(6, 0, 2), 300, 1'b0, "H6a the 300 bytes in order");
    ledger_clear;
    dma_prog(8'h46, 16'h8000, 16'd1024);
    data_cmd(8'h46, 8'h06, 8'h03, 8'h03);
    wait_irq(4000000, "H6b the READ after a mid-sector count");
    get_result;
    expect8(rs[0], 8'h00, "H6b ST0 (the count ends with the sector)");
    expecti(nrec, 1024, "H6b 1024 bytes");
    cmp_rec(raw_off(6, 0, 3), 1024, 1'b0, "H6b and they are its own sector");

    // ---- H7: a DOR reset 0..4 cycles after a strobe of a DMA READ ----
    for (off = 0; off <= 4; off = off + 1) begin
      ledger_clear;
      dma_prog(8'h46, 16'h8000, 16'd1024);
      data_cmd(8'h46, 8'h10 + off[7:0], 8'h01, 8'h08);
      dor_reset_at(300, off);
      dma_stop;
      // The strobe of byte 300 (the 301st) is in or before the reset's cycle, so the controller
      // takes it: exactly 301 medium advances whatever the offset. A strobe the engine committed
      // to before the reset (its S_IDLE sample, three cycles after S_DEV) can still follow with
      // the idle port's 0xFF; that is the engine's, not a medium byte, and is not compared.
      expecti(nadv, 301, "H7 medium advances up to the reset: one per byte taken");
      if (nrec < 301 || nrec > 302) begin
        $display("  FAIL: H7 off %0d: %0d strobes around a reset at byte 300", off, nrec);
        fails = fails + 1;
      end
      cmp_rec(raw_off(16 + off, 0, 1), 301, 1'b0, "H7 the bytes before the reset, in order");
      ledger_clear;
      dma_prog(8'h46, 16'h8000, 16'd1024);
      data_cmd(8'h46, 8'h10 + off[7:0], 8'h02, 8'h02);
      wait_irq(4000000, "H7 the READ after the reset");
      get_result;
      expect8(rs[0], 8'h00, "H7 the READ after the reset completes");
      expecti(nrec, 1024, "H7 the READ after the reset: 1024 bytes");
      cmp_rec(raw_off(16 + off, 0, 2), 1024, 1'b0, "H7 the READ after the reset: its own sector");
    end

    // ---- H8: a DOR reset 0..4 cycles after a strobe of a DMA WRITE ----
    for (off = 0; off <= 4; off = off + 1) begin
      for (j = 0; j < 1024; j = j + 1) gmem[j] = pw(80 + off, j);
      ledger_clear; ha0 = hw_a;
      dma_prog(8'h4A, 16'h0000, 16'd1024);
      data_cmd(8'h45, 8'h08, 8'h01 + off, 8'h01 + off);
      dor_reset_at(300, off);
      dma_stop;
      expecti(nadv, 301, "H8 medium advances up to the reset: one per byte taken");
      repeat (20000) @(negedge clk);
      expecti(hw_a - ha0, 0, "H8 nothing of the cut-off write reached the image");
      cmp_raw("H8 the image is unchanged after the reset");
      for (j = 0; j < 1024; j = j + 1) gmem[j] = pw(90 + off, j);
      ledger_clear;
      dma_prog(8'h4A, 16'h0000, 16'd1024);
      data_cmd(8'h45, 8'h08, 8'h01 + off, 8'h01 + off);
      wait_irq(4000000, "H8 the WRITE after the reset");
      get_result;
      expect8(rs[0], 8'h00, "H8 the WRITE after the reset completes");
      expecti(nadv, 1024, "H8 the WRITE after the reset: one advance per byte");
      for (j = 0; j < 1024; j = j + 1) expA[raw_off(8, 0, 1 + off) + j] = pw(90 + off, j);
      cmp_raw("H8 the WRITE after the reset landed exactly");
    end

    // ---- H9: a mount of drive 0 0..3 cycles after a strobe of a DMA READ ----
    for (off = 0; off <= 3; off = off + 1) begin
      ledger_clear;
      dma_prog(8'h46, 16'h8000, 16'd1024);
      data_cmd(8'h46, 8'h09, 8'h01 + off, 8'h08);
      mount_at(300, off, ~b_is_new);
      wait_irq(4000000, "H9 the READ a mount cut off answers");
      get_result;
      dma_stop;
      if (nrec < 300 || nrec > 304) begin
        $display("  FAIL: H9 off %0d: %0d bytes taken around a mount at byte 300", off, nrec);
        fails = fails + 1;
      end
      // the bytes before the mount are the OLD image's
      n = 0;
      for (j = 0; j < 300; j = j + 1)
        if (rec[j] !== (b_is_new ? expA[raw_off(9, 0, 1 + off) + j] : pnew(raw_off(9, 0, 1 + off) + j)))
          n = n + 1;
      expecti(n, 0, "H9 the bytes before the mount are the old image's, in order");
      repeat (6000) @(negedge clk);
      ledger_clear;
      dma_prog(8'h46, 16'h8000, 16'd1024);
      data_cmd(8'h46, 8'h09, 8'h06, 8'h06);
      wait_irq(4000000, "H9 the READ after the mount");
      get_result;
      expect8(rs[0], 8'h00, "H9 the READ after the mount completes");
      expecti(nrec, 1024, "H9 the READ after the mount: 1024 bytes");
      cmp_rec(raw_off(9, 0, 6), 1024, b_is_new, "H9 the READ after the mount: the new image's sector");
    end

    // ---- H10: a mount of drive 0 0..3 cycles after a strobe of a DMA WRITE ----
    // b_is_new alternates: the write starts on one image and the mount brings the other.
    for (off = 0; off <= 3; off = off + 1) begin
      for (j = 0; j < 1024; j = j + 1) gmem[j] = pw(100 + off, j);
      ledger_clear; ha0 = hw_a; hn0 = hw_n;
      dma_prog(8'h4A, 16'h0000, 16'd1024);
      data_cmd(8'h45, 8'h0A, 8'h01 + off, 8'h01 + off);
      mount_at(300, off, ~b_is_new);
      wait_irq(4000000, "H10 the WRITE a mount cut off answers");
      get_result;
      dma_stop;
      repeat (20000) @(negedge clk);
      expecti(hw_a - ha0, 0, "H10 nothing of the cut-off write reached the old image");
      expecti(hw_n - hn0, 0, "H10 nothing of the cut-off write reached the new image");
      cmp_raw("H10 image A unchanged");
      cmp_new("H10 image N unchanged");
    end

    // ---- H11: a raw FORMAT of C11 H0 (N 3, SC 8, D 0xE5): 8192 filler bytes back to back ----
    // FDC_WriteID -> fdd_formatinit_xdf (io/fdc.c:723-765, diskimage/fd/fdd_xdf.c:433-517): the
    // track's SC sectors of 128 << N bytes of D, success7, no ID byte taken.
    seek_to(8'h0B);
    ledger_clear;
    wr8(3'd1, 8'h4D); wr8(3'd1, 8'h00); wr8(3'd1, 8'h03); wr8(3'd1, 8'h08);
    wr8(3'd1, 8'h74); wr8(3'd1, 8'hE5);
    t_cmd = cyc;
    wait_irq(4000000, "H11 FORMAT");
    tcost = cyc - t_cmd;
    $display("COST H11 raw FORMAT 8x1024 filler: %0d cycles from the command to the interrupt", tcost);
    get_result;
    expect8(rs[0], 8'h00, "H11 FORMAT ST0");
    expecti(nstb, 0, "H11 no DMA byte");
    expecti(nadv, 8192, "H11 medium advances: one per filler byte");
    cost_check("H11", tcost, COST_H11_BASE, COST_H11, nadv);
    for (j = 0; j < 8192; j = j + 1) expA[raw_off(11, 0, 1) + j] = 8'hE5;
    cmp_raw("H11 the track holds D and nothing else changed");

    // ---- H12: a DOR reset on and next to the media request of a READ, a WRITE and a READ ID ----
    // Each kind is first run undisturbed to measure the request's delay from the command (and to
    // check that the command itself is served). The request is issued in the cycle right after
    // the last command byte is taken (dreq = 0, checked), so the cycle before it carries that
    // byte's own write and no reset can land there; the reset lands in the request's own cycle
    // and in each of the four after it. After every reset the medium is back in `ready`, nothing
    // of the cut-off command reached the image, and the same command is served again.
    for (k = 0; k < 3; k = k + 1) begin : h12_kind
      integer kk, oo;
      kk = k;
      for (oo = -1; oo <= 4; oo = oo + 1) begin
        // oo = -1: the undisturbed run that measures the request's delay
        for (j = 0; j < 1024; j = j + 1) gmem[j] = pw(120 + kk * 8 + oo + 1, j);
        ledger_clear; ha0 = hw_a; hn0 = hw_n; nreq = 0;
        if (kk == 0) dma_prog(8'h46, 16'h8000, 16'd1024);
        if (kk == 1) dma_prog(8'h4A, 16'h0000, 16'd1024);
        req_cmd(kk, 8'h0C, 8'h01 + kk[7:0]);
        if (oo == -1) begin
          wait_irq(4000000, "H12 the undisturbed command");
          dreq = t_req - t_cmd;
          expecti(nreq, 1, "H12 the undisturbed command: one media request");
          expecti(dreq, 0, "H12 the request is issued the cycle after the last command byte");
        end
        else begin
          dor_reset_req(dreq, oo, (kk == 0) ? "H12 READ" : (kk == 1) ? "H12 WRITE" : "H12 READ ID");
          dma_stop;
          repeat (20000) @(negedge clk);
          expecti(nadv, 0, "H12 no byte reached the medium before the reset");
          expecti(hw_a - ha0, 0, "H12 nothing of the cut-off command reached the image");
          cmp_raw("H12 the image is unchanged after the reset");
          // the same command again, served
          for (j = 0; j < 1024; j = j + 1) gmem[j] = pw(120 + kk * 8 + oo + 1, j);
          ledger_clear;
          if (kk == 0) dma_prog(8'h46, 16'h8000, 16'd1024);
          if (kk == 1) dma_prog(8'h4A, 16'h0000, 16'd1024);
          req_cmd(kk, 8'h0C, 8'h01 + kk[7:0]);
          wait_irq(4000000, "H12 the command after the reset");
        end
        get_result;
        dma_stop;
        expect8(rs[0], 8'h00, "H12 the command (undisturbed, or after the reset) completes");
        if (kk == 0) begin
          expecti(nrec, 1024, "H12 READ: 1024 bytes");
          cmp_rec(raw_off(12, 0, 1), 1024, 1'b0, "H12 READ: its own sector");
        end
        if (kk == 1) begin
          expecti(nadv, 1024, "H12 WRITE: one advance per byte");
          for (j = 0; j < 1024; j = j + 1) expA[raw_off(12, 0, 2) + j] = pw(120 + kk * 8 + oo + 1, j);
          cmp_raw("H12 WRITE: the sector landed exactly");
        end
        if (kk == 2) begin
          expecti(rlen, 7, "H12 READ ID: seven result bytes");
          expect8(rs[3], 8'h0C, "H12 READ ID: C is the track's");
          expect8(rs[4], 8'h00, "H12 READ ID: H 0");
          expect8(rs[6], 8'h03, "H12 READ ID: N 3 (1024-byte sectors)");
          if (rs[5] < 8'h01 || rs[5] > 8'h08) begin
            $display("  FAIL: H12 READ ID: R %02x is not one of the track's eight sectors", rs[5]);
            fails = fails + 1;
          end
        end
      end
    end

    // ==== VERDICT ====
    if (fails == 0) begin
      $display("TB_PC9821_FDC_HANDOFF: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_FDC_HANDOFF: FAIL (%0d errors)", fails);
  end

endmodule
