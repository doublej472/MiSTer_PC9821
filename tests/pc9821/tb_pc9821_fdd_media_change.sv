`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_FDD_MEDIA_CHANGE: a floppy is mounted, swapped and ejected while the core runs, without a reset, and the guest sees NP2kai's media change: every mount event of a drive leaves SENSE INTERRUPT STATUS = AI|NR|drv with the interrupt, an insert keeps the drive not ready for the 20-frame insert delay and then reports AI|drv with the interrupt, and the drive's READY (ST3 RDY) follows; an eject or swap UNDER a READ DATA is undefined for the guest, and what is pinned there is only that NOTHING HANGS - mid-DMA on channel 2 at 1, 511, 512, 700 and 1000 bytes, before the first byte and while the request is being issued, the controller recovers through the guest's own DOR reset to an idle MSR, the bytes moved before the change are the old image's, the other drive reads byte-exact across it, and a re-inserted or swapped-in image then reads byte-exact; a mount on the OTHER drive while a read is in flight lets the read finish with its own image's bytes; back-to-back mounts leave the LAST image mounted; a remount of the same image and an insert into an empty drive both read correctly; a mount level held for many cycles is one media change; and a request accepted while the OTHER drive's read-ahead of the same block index is still outstanding is served its own image's block, never the other drive's (the stale-block guard). FAIL-FIRST: the base tree finished the ejected read with success out of stale blocks and left READY standing until the deferred walk; the osd-mount tree raised no ready-change interrupt; with the stale-block guard removed, M7 reads drive 1's bytes on drive 0.
//
// THE CLASSES ARE NP2kai's: diskdrv_setfddex (fdd/
// diskdrv.c:256-284) sets `fdc.stat[drv] = FDCRLT_AI | FDCRLT_NR | drv` and interrupts on every
// change, arms DISK_DELAY = 20 frames for an insert (:15), and diskdrv_readyfddex (:225-249) sets
// `FDCRLT_AI | drv` and interrupts when it runs out (gate open here: chgreg = 3 after reset).
// tb_pc9821_fdc_ready_change pins the gate and the frame count at the controller alone; this
// bench runs the same change through the real medium and the real adapter.
// WHAT IS NOT PINNED: the answer of a command whose medium left under it (ejecting a
// floppy during a read is undefined behaviour).
//
// THE PATH IS THE REAL ONE: pc9821_fdc, pc9821_fdd_media and pc9821_block_share (with its
// pc9821_block_io engine), with a host model for both floppy slots and a uPD71071-shaped DMA
// model that can be PAUSED at a byte count - which is how an eject is landed mid-DMA.
//
// ==== DUT ====
`define IMGMAX 1310720

module tb_pc9821_fdd_media_change;

  reg clk = 0;
  always #5 clk = ~clk;   // 100 MHz, the same clk_sys the fit uses
  reg reset = 1;

  // ==== the images: two D88s with different tables, sizes and contents ====
  // A (drive 0, slot 1): track 0 = R1 1024 B, R2 1024 B; track 1 = ONE header, R1 1024 B.
  localparam integer A_T0 = 688;                                // 0x2B0
  localparam integer A_T1 = A_T0 + 16 + 1024 + 16 + 1024;       // 0xAD0
  localparam integer A_BYTES = A_T1 + 16 + 1024;                // 3808
  // B (drive 1, slot 2): track 0 = R1 1024 B, R2 512 B STORED (the zero tail);
  // track 1 = TWO headers, R1 and R3, both 1024 B; track 72 (C=36,H=0) and track 144
  // (C=72,H=0) are one 1024 B sector each. Those two HIGH tracks are the range P1-a's
  // 328-entry array bound did not cover for drive 1 (index {1,track} = 328 and 400).
  localparam integer B_T0 = 688;
  localparam integer B_T1 = B_T0 + 16 + 1024 + 16 + 512;        // 0x8D0
  localparam integer B_T72 = B_T1 + 16 + 1024 + 16 + 1024;      // D88 track 72 (C=36,H=0)
  localparam integer B_T144 = B_T72 + 16 + 1024;                // D88 track 144 (C=72,H=0)
  localparam integer B_BYTES = B_T144 + 16 + 1024;
  // C (drive 1's remount): a RAW body whose size is NP2kai's 154-half-track row
  // (diskimage/fd/fdd_xdf.c:30-34), filled with a third pattern over its first 16 KiB.
  localparam integer C_BYTES = 1261568;

  reg [7:0] imgA [0:`IMGMAX-1];
  reg [7:0] imgB [0:`IMGMAX-1];
  reg [7:0] imgC [0:`IMGMAX-1];

  function automatic [7:0] pa(input [7:0] r, input [7:0] hh, input integer j);
    pa = (j * 7 + r * 13 + hh * 3 + 0) & 8'hFF;
  endfunction
  function automatic [7:0] pb(input [7:0] r, input [7:0] hh, input integer j);
    pb = (j * 11 + r * 29 + hh * 5 + 1) & 8'hFF;
  endfunction
  // The RAW image's content is a function of the FILE OFFSET, because that is what the raw
  // path serves: ((((C*2+H) * sects) + R-1) << (7+N)), fdd_read_xdf :348-352.
  function automatic [7:0] praw(input integer off);
    praw = (off * 3 + 7) & 8'hFF;
  endfunction

  task automatic put_d88_header(input integer which, input integer bytes,
                                input integer t0, input integer t1);
    integer t, j;
    begin
      // Only THIS image's header area is cleared: the two images are built one after the
      // other and each must survive the other's build.
      for (j = 0; j < 688; j = j + 1) begin
        if (which == 0) imgA[j] = 8'h00; else imgB[j] = 8'h00;
      end
      for (t = 0; t < 164; t = t + 1) begin
        if (t > 1) begin
          if (which == 0) begin
            imgA[8'h20 + 4*t + 0] = 8'h00; imgA[8'h20 + 4*t + 1] = 8'h00;
            imgA[8'h20 + 4*t + 2] = 8'h00; imgA[8'h20 + 4*t + 3] = 8'h00;
          end else begin
            imgB[8'h20 + 4*t + 0] = 8'h00; imgB[8'h20 + 4*t + 1] = 8'h00;
            imgB[8'h20 + 4*t + 2] = 8'h00; imgB[8'h20 + 4*t + 3] = 8'h00;
          end
        end
      end
      if (which == 0) begin
        // fd_type = 0x20: DISKTYPE_2HD is major 2 (NP2kai diskimage/fd/fddfile.h:42-44),
        // MAME maps 0x20 to DSHD, and the one real D88 in this tree carries it. 0x30 is
        // NOT the 2HD code; see tb_pc9821_fdd_media_d88 and the module's container test.
        imgA[8'h1B] = 8'h20;
        imgA[8'h1C] = bytes[7:0];   imgA[8'h1D] = bytes[15:8];
        imgA[8'h1E] = bytes[23:16]; imgA[8'h1F] = bytes[31:24];
        imgA[8'h20] = t0[7:0]; imgA[8'h21] = t0[15:8];         // trackp[0] -> track 0
        imgA[8'h24] = t1[7:0]; imgA[8'h25] = t1[15:8];         // trackp[1] -> track 1
      end else begin
        imgB[8'h1B] = 8'h20;
        imgB[8'h1C] = bytes[7:0];   imgB[8'h1D] = bytes[15:8];
        imgB[8'h1E] = bytes[23:16]; imgB[8'h1F] = bytes[31:24];
        imgB[8'h20] = t0[7:0]; imgB[8'h21] = t0[15:8];
        imgB[8'h24] = t1[7:0]; imgB[8'h25] = t1[15:8];
      end
    end
  endtask

  task automatic put_sec_header(input integer which, input integer off,
                                input [7:0] c, h, r, nn,
                                input integer nsec, input integer size);
    begin
      if (which == 0) begin
        imgA[off+0] = c; imgA[off+1] = h; imgA[off+2] = r; imgA[off+3] = nn;
        imgA[off+4] = nsec[7:0]; imgA[off+5] = nsec[15:8];
        imgA[off+6] = 8'h00;                                    // mfm_flg: 0x00 = MFM, the mode these reads use (0x40 = FM, NP2kai searchsector_d88)
        imgA[off+14] = size[7:0]; imgA[off+15] = size[15:8];
      end else begin
        imgB[off+0] = c; imgB[off+1] = h; imgB[off+2] = r; imgB[off+3] = nn;
        imgB[off+4] = nsec[7:0]; imgB[off+5] = nsec[15:8];
        imgB[off+6] = 8'h00;
        imgB[off+14] = size[7:0]; imgB[off+15] = size[15:8];
      end
    end
  endtask

  task automatic put_sec_data(input integer which, input integer off,
                              input [7:0] r, hh, input integer size);
    integer j;
    begin
      for (j = 0; j < size; j = j + 1) begin
        if (which == 0) imgA[off + j] = pa(r, hh, j);
        else             imgB[off + j] = pb(r, hh, j);
      end
    end
  endtask

  task automatic build_d88_a;
    begin
      put_d88_header(0, A_BYTES, A_T0, A_T1);
      put_sec_header(0, A_T0 + 0,    8'h00, 8'h00, 8'h01, 8'h03, 2, 1024);
      put_sec_data  (0, A_T0 + 16,   8'h01, 8'h00, 1024);
      put_sec_header(0, A_T0 + 1040, 8'h00, 8'h00, 8'h02, 8'h03, 2, 1024);
      put_sec_data  (0, A_T0 + 1056, 8'h02, 8'h00, 1024);
      put_sec_header(0, A_T1 + 0,    8'h00, 8'h01, 8'h01, 8'h03, 1, 1024);
      put_sec_data  (0, A_T1 + 16,   8'h01, 8'h01, 1024);
    end
  endtask

  task automatic build_d88_b;
    begin
      put_d88_header(1, B_BYTES, B_T0, B_T1);
      // THE HIGH TRACKS P1-a's ARRAY BOUND MISSED. The table is addressed {drive, track},
      // so drive 1's entries are indices 256..419; trackp[72] is the FIRST index past the
      // old 328-entry bound and trackp[144] is deep inside the gap.
      imgB[8'h20 + 4*72  + 0] = B_T72[7:0];  imgB[8'h20 + 4*72  + 1] = B_T72[15:8];
      imgB[8'h20 + 4*144 + 0] = B_T144[7:0]; imgB[8'h20 + 4*144 + 1] = B_T144[15:8];
      put_sec_header(1, B_T0 + 0,    8'h00, 8'h00, 8'h01, 8'h03, 2, 1024);
      put_sec_data  (1, B_T0 + 16,   8'h01, 8'h00, 1024);
      put_sec_header(1, B_T0 + 1040, 8'h00, 8'h00, 8'h02, 8'h03, 2, 512);
      put_sec_data  (1, B_T0 + 1056, 8'h02, 8'h00, 512);
      put_sec_header(1, B_T1 + 0,    8'h00, 8'h01, 8'h01, 8'h03, 2, 1024);
      put_sec_data  (1, B_T1 + 16,   8'h01, 8'h01, 1024);
      put_sec_header(1, B_T1 + 1040, 8'h00, 8'h01, 8'h03, 8'h03, 2, 1024);
      put_sec_data  (1, B_T1 + 1056, 8'h03, 8'h01, 1024);
      put_sec_header(1, B_T72 + 0,   8'h24, 8'h00, 8'h01, 8'h03, 1, 1024);
      put_sec_data  (1, B_T72 + 16,  8'h24, 8'h00, 1024);
      put_sec_header(1, B_T144 + 0,  8'h48, 8'h00, 8'h01, 8'h03, 1, 1024);
      put_sec_data  (1, B_T144 + 16, 8'h48, 8'h00, 1024);
    end
  endtask

  task automatic build_raw_c;
    integer j;
    begin
      for (j = 0; j < 16384; j = j + 1) imgC[j] = praw(j);
    end
  endtask

  // ==== DUT: the real controller, the real medium, the real shared adapter ====
  reg        cs = 0, wr = 0, rd = 0;
  reg  [2:0] addr = 0;
  reg  [7:0] din = 0;
  wire [7:0] dout;
  wire       irq;

  wire [1:0]  fdd_present;         // one bit per DRIVE, from the media module
  wire [1:0]  fdd_chg;             // [u] the medium's change tag (one toggle per mount event)
  // The guest's frame: a short synthetic one (FRAME_CYC clocks) so the 20-frame insert delay is
  // 20 * FRAME_CYC clocks of simulation, not 20 real frames.
  localparam integer FRAME_CYC = 500;
  reg         ftick = 1'b0;
  integer     fcnt = 0;
  always @(posedge clk) begin
    ftick <= (fcnt == FRAME_CYC - 1);
    fcnt  <= (fcnt == FRAME_CYC - 1) ? 0 : fcnt + 1;
  end
  wire [1:0]  fdd_wp;     // [u] the media module's write-protect state, one bit per drive
  wire        fdd_req, fdd_req_hdr, fdd_adv;
  wire [1:0]  fdd_unit;
  wire [7:0]  fdd_c, fdd_h, fdd_r, fdd_n, fdd_idx;
  wire [7:0] fdd_tc;   // the physical track (pc9821_fdc's media_tc)
  wire       fdd_hd;
  wire       fdd_mf;
  wire       fdd_2hd;
  wire       fdd_rpm;
  wire        fdd_ready, fdd_rdy, fdd_hdrv, fdd_err;
  wire [7:0]  fdd_dout, fdd_hr, fdd_hn, fdd_hs;

  wire        blk_rd, blk_busy, blk_done, blk_error, blk_slot;
  wire [15:0] blk_lba;
  wire        blk_fill_we;
  wire [ 7:0] blk_fill_addr;
  wire [15:0] blk_fill_data;
  wire [31:0] dbg_hps_cycles;

  wire        dma_drq;
  reg         dma_dack = 0, dma_stb = 0, dma_tc = 0;
  wire [7:0]  dma_dout;

  pc9821_fdc fdc (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr),
      .wr(wr), .rd(rd), .din(din), .dout(dout), .irq(irq),
      // The controller's per-unit presence vector: drive 0 is bit 0, drive 1 is bit 1,
      // which is what gives an unmounted drive 1 its own no-media answer (U1/U5).
      .media_present({2'b00, fdd_present}), .writeprotect({2'b00, fdd_wp}),
      .media_chg({2'b00, fdd_chg}), .frame_tick(ftick),
      .media_req(fdd_req), .media_req_hdr(fdd_req_hdr), .media_unit(fdd_unit),
      .media_c(fdd_c), .media_h(fdd_h), .media_tc(fdd_tc), .media_hd(fdd_hd), .media_mf(fdd_mf), .media_2hd(fdd_2hd), .media_rpm(fdd_rpm), .media_r(fdd_r), .media_n(fdd_n),
      .media_idx(fdd_idx),
      .media_ready(fdd_ready), .media_rdy(fdd_rdy), .media_hdrv(fdd_hdrv),
      .media_err(fdd_err), .media_dout(fdd_dout),
      .media_hr(fdd_hr), .media_hn(fdd_hn), .media_hs(fdd_hs),
      .media_adv(fdd_adv),
      .dma_drq(dma_drq), .dma_dack(dma_dack), .dma_stb(dma_stb), .dma_tc(dma_tc),
      .dma_dout(dma_dout)
  );

  // The two drives' image slots, wired as pc9821_system wires them: `img_size` is ONE
  // hps_io register feeding BOTH slots (sys/hps_io.sv:145 (output reg [63:0] img_size,     // size of image in bytes. v)), which is why this bench has one
  // size register and two mount pulses - and why the mount tasks set it before each pulse.
  reg        mnt0 = 0, mnt1 = 0;
  reg [63:0] img_size = 0;

  pc9821_fdd_media media (
      .clk(clk), .reset(reset),
      .img_mounted(mnt0), .img_size(img_size), .img_readonly(1'b1),
      .img1_mounted(mnt1), .img1_size(img_size),
      .blk_req_rd(blk_rd), .blk_req_lba(blk_lba), .blk_slot(blk_slot),
      .blk_done(blk_done), .blk_err(blk_error), .blk_busy(blk_busy),
      .blk_fill_we(blk_fill_we), .blk_fill_addr(blk_fill_addr),
      .blk_fill_data(blk_fill_data),
      .present(fdd_present), .writeprotect(fdd_wp), .chg(fdd_chg),
      .req(fdd_req), .req_hdr(fdd_req_hdr), .unit(fdd_unit),
      .req_c(fdd_c), .req_h(fdd_h), .req_tc(fdd_tc), .req_hd(fdd_hd), .req_mf(fdd_mf), .req_2hd(fdd_2hd), .req_rpm(fdd_rpm), .req_r(fdd_r), .req_n(fdd_n), .req_idx(fdd_idx),
      .ready(fdd_ready), .rdy(fdd_rdy), .hdrv(fdd_hdrv), .err(fdd_err),
      .dout(fdd_dout), .adv(fdd_adv),
      .hdr_r(fdd_hr), .hdr_n(fdd_hn), .hdr_sects(fdd_hs)
  );

  // ==== the HPS host model: both slots, one transfer at a time ====
  reg        sd_ack_b = 0, sd_ack_c = 0, sd_buff_wr = 0;
  reg [12:0] sd_buff_addr = 0;
  reg [15:0] sd_buff_dout = 0;
  wire [31:0] sd_lba_b, sd_lba_c;
  wire [ 5:0] sd_blk_cnt_b, sd_blk_cnt_c;
  wire        sd_rd_b, sd_wr_b, sd_rd_c, sd_wr_c;
  wire [15:0] sd_buff_din_b, sd_buff_din_c;

  pc9821_block_share share (
      // Slot D (the second hard disk): unmounted; every disk request is for slot A.




      .clk(clk), .rst_n(!reset),
      // the hard disk's slot: unmounted, no requests
      .a_img_mounted(1'b0), .a_img_readonly(1'b1), .a_img_size(64'd0),
      .a_mounted(), .a_readonly(), .a_capacity(),
      .a_req_read(1'b0), .a_req_write(1'b0), .a_req_lba(32'd0),
      .a_req_done(), .a_req_error(), .a_busy(),
      .a_buf_we(), .a_buf_addr(), .a_buf_data(),
      .a_buf_rd_addr(), .a_buf_rd_data(16'd0),
      .a_sd_lba(), .a_sd_blk_cnt(), .a_sd_rd(), .a_sd_wr(), .a_sd_ack(1'b0),
      .a_sd_buff_din(),
      // the floppy's ONE device port: drive 0 is slot B and drive 1 is slot C, told apart
      // by the drive tag the medium holds with its request (`blk_slot` -> b_req_slot)
      .b_img_mounted(mnt0), .b_img_readonly(1'b1), .b_img_size(img_size),
      .b_req_read(blk_rd), .b_req_lba(blk_lba), .b_req_slot(blk_slot),
      .b_req_done(blk_done), .b_req_error(blk_error), .b_busy(blk_busy),
      .b_buf_we(blk_fill_we), .b_buf_addr(blk_fill_addr), .b_buf_data(blk_fill_data),
      .b_sd_lba(sd_lba_b), .b_sd_blk_cnt(sd_blk_cnt_b),
      .b_sd_rd(sd_rd_b), .b_sd_wr(sd_wr_b),
      .b_sd_ack(sd_ack_b), .b_sd_buff_din(sd_buff_din_b),
      .c_img_mounted(mnt1), .c_img_readonly(1'b1), .c_img_size(img_size),
      .c_sd_lba(sd_lba_c), .c_sd_blk_cnt(sd_blk_cnt_c),
      .c_sd_rd(sd_rd_c), .c_sd_wr(sd_wr_c),
      .c_sd_ack(sd_ack_c), .c_sd_buff_din(sd_buff_din_c),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
      .dbg_hps_cycles(dbg_hps_cycles)
  );

  // Which image a slot C handshake is answered from: 0 = imgB (the D88), 1 = imgC (the RAW
  // remount). Set by the mount sequence, exactly as the OSD's mount would pick a file.
  reg c_is_raw = 0;
  // Slot B's image for M7: 0 = imgA (the D88), 1 = imgC's bytes XOR 0x5A - a RAW body of the same
  // geometry as slot C's but different content, so a block of one can never pass for the other.
  reg b_is_raw = 0;

  reg [12:0] widx, wtotal;
  reg [15:0] hword_q;   // the word the host model is about to present (see its use)
  reg [31:0] hlba;
  reg        hbusy, hlast;
  reg  [1:0] hwhich;

  task automatic word_for(input [1:0] which, input [31:0] lba, input [7:0] w,
                          output [15:0] v);
    integer base;
    begin
      base = lba * 512 + w * 2;
      if (which == 2'd0)      v = {imgA[base + 1], imgA[base]};
      else if (which == 2'd1) v = {imgB[base + 1], imgB[base]};
      else if (which == 2'd2) v = {imgC[base + 1], imgC[base]};
      else                    v = {imgC[base + 1] ^ 8'h5A, imgC[base] ^ 8'h5A};
    end
  endtask

  always @(posedge clk) begin
    if (reset) begin
      sd_ack_b <= 1'b0; sd_ack_c <= 1'b0; sd_buff_wr <= 1'b0;
      hbusy <= 1'b0; hlast <= 1'b0; widx <= 13'd0; hwhich <= 2'd0;
    end else if (!hbusy) begin
      sd_buff_wr <= 1'b0;
      if (sd_rd_b) begin
        hbusy    <= 1'b1;
        sd_ack_b <= 1'b1;
        widx     <= 13'd0;
        hlba     <= sd_lba_b;
        hwhich   <= b_is_raw ? 2'd3 : 2'd0;
        wtotal   <= ({7'd0, sd_blk_cnt_b} + 13'd1) * 13'd256 - 13'd1;
      end else if (sd_rd_c) begin
        hbusy    <= 1'b1;
        sd_ack_c <= 1'b1;
        widx     <= 13'd0;
        hlba     <= sd_lba_c;
        hwhich   <= c_is_raw ? 2'd2 : 2'd1;
        wtotal   <= ({7'd0, sd_blk_cnt_c} + 13'd1) * 13'd256 - 13'd1;
      end
    end else begin
      sd_buff_wr   <= 1'b1;
      sd_buff_addr <= widx;
      // The word is formed in a process-local variable and reaches the port through a
      // NONBLOCKING assignment, like sd_buff_addr and sd_buff_wr beside it: hps_io drives
      // all three from registers (sys/hps_io.sv:156 `output reg [DW:0] sd_buff_dout,`). A
      // blocking write here is read by the adapter's own posedge process in the same time
      // step, a race IEEE 1800-2017 4.7 leaves to the simulator's process order (Verilator
      // 5.052 resolved it as the old word, 5.054 as the new one, one word early).
      word_for(hwhich, hlba + {19'd0, widx[12:8]}, widx[7:0], hword_q);
      sd_buff_dout <= hword_q;
      if (hlast) begin
        hbusy      <= 1'b0;
        sd_ack_b   <= 1'b0;
        sd_ack_c   <= 1'b0;
        sd_buff_wr <= 1'b0;
        hlast      <= 1'b0;
      end else if (widx == wtotal) begin
        hlast <= 1'b1;
      end else begin
        widx <= widx + 13'd1;
      end
    end
  end


  // ==== the DMA model: one strobe per DRQ, TC coincident with the final one ====
  // It can be PAUSED once `dm_n` reaches `dm_pause_at`: the strobes stop with DRQ still up,
  // which is a DMA transfer interrupted mid-sector - the window the eject lands in.
  reg [15:0] dm_left;
  reg        dm_run;
  integer    dm_n;
  integer    dm_pause_at = 32'h7FFFFFFF;
  reg  [7:0] dm_bytes [0:8191];

  reg armed;
  always @(posedge clk) begin
    dma_dack <= 1'b0;
    dma_stb  <= 1'b0;
    dma_tc   <= 1'b0;
    if (reset) begin
      dm_left <= 16'd0; dm_run <= 1'b0; dm_n = 0; armed <= 1'b0;
    end else if (armed) begin
      if (dm_n < 8192) dm_bytes[dm_n] = dma_dout;
      dm_n     = dm_n + 1;
      dm_left <= dm_left - 16'd1;
      if (dm_left == 16'd1) dm_run <= 1'b0;
      armed <= 1'b0;
    end else if (dm_run && dma_drq && (dm_left != 16'd0) && (dm_n < dm_pause_at)) begin
      dma_dack <= 1'b1;
      dma_stb  <= 1'b1;
      dma_tc   <= (dm_left == 16'd1);
      armed    <= 1'b1;
    end
  end

  // ==== CHECKS ====
  integer fails = 0;
  integer i, n;
  initial begin
    #80_000_000;
    $fatal(1, "TB_PC9821_FDD_MEDIA_CHANGE: watchdog timeout (no verdict reached)");
  end

  // A runaway failure is ended, not logged forever.
  always @(posedge clk)
    if (fails > 500) $fatal(1, "TB_PC9821_FDD_MEDIA_CHANGE: FAIL (more than 500 errors, stopped)");

  task automatic expect8(input [7:0] got, input [7:0] want, input [8*96-1:0] what);
    begin
      if (got !== want) begin
        $display("  FAIL: %0s: got %02x, expected %02x", what, got, want);
        fails = fails + 1;
      end
    end
  endtask

  task automatic expecti(input integer got, input integer want, input [8*96-1:0] what);
    begin
      if (got !== want) begin
        $display("  FAIL: %0s: got %0d, expected %0d", what, got, want);
        fails = fails + 1;
      end
    end
  endtask

  // The byte the transfer moved at index k must be the one THAT drive's image holds there:
  // a D88 read starts the stream at the matched sector's data (so index k is byte k of that
  // sector), a sector whose stored size is short delivers zeroes after it (fdd_read_d88
  // :427-443), and a RAW read is the image's bytes at the geometry's offset.
  task automatic check_sector(input integer which, input [7:0] r, hh,
                              input integer stored, input integer nb);
    reg [7:0] want;
    integer bad_lines;
    begin
      bad_lines = 0;
      for (i = 0; i < nb; i = i + 1) begin
        if (which == 0)      want = pa(r, hh, i);
        else if (which == 1) want = (i < stored) ? pb(r, hh, i) : 8'h00;
        else if (which == 3) want = 8'h5A ^ praw((({15'd0, hh} * 16'd8) + {15'd0, r} - 16'd1) * 16'd1024
                                         + i);
        else                 want = praw((({15'd0, hh} * 16'd8) + {15'd0, r} - 16'd1) * 16'd1024
                                         + i);
        if (dm_bytes[i] !== want) begin
          // BOUNDED: at most 8 lines per sector, so a wrong sector cannot flood the log.
          if (bad_lines < 8)
            $display("  FAIL: image %0d sector (H=%0d,R=%0d) byte %0d is %02x, that image holds %02x",
                     which, hh, r, i, dm_bytes[i], want);
          bad_lines = bad_lines + 1;
          fails = fails + 1;
        end
      end
    end
  endtask

  // ==== the controller's port helpers (the iobus S_BYTE contract) ====
  task automatic wr8(input [2:0] a, input [7:0] d);
    begin
      @(negedge clk); cs = 1; addr = a; wr = 1; rd = 0; din = d;
      @(posedge clk);
      @(negedge clk); cs = 0; wr = 0;
    end
  endtask

  reg [7:0] rd_val;
  task automatic rd8(input [2:0] a);
    begin
      @(negedge clk); cs = 1; addr = a; wr = 0; rd = 1;
      #1 rd_val = dout;
      @(posedge clk);
      @(negedge clk); cs = 0; rd = 0;
    end
  endtask

  reg [7:0] g_rs [0:6];
  integer   g_rlen;
  task automatic get_result;
    begin
      g_rlen = 0;
      for (i = 0; i < 8; i = i + 1) g_rs[i] = 8'hFF;
      rd8(3'd0);
      while (((rd_val & 8'h40) != 0) && (g_rlen < 8)) begin
        rd8(3'd1);
        g_rs[g_rlen] = rd_val;
        g_rlen = g_rlen + 1;
        rd8(3'd0);
      end
    end
  endtask

  task automatic wait_irq(input integer maxc);
    begin
      n = 0;
      while (!irq && n < maxc) begin @(negedge clk); n = n + 1; end
      if (!irq) begin
        $display("  FAIL: interrupt never came");
        fails = fails + 1;
      end
    end
  endtask

  // READ DATA: opcode, then us|hd<<2, C, H, R, N, EOT, GPL, DTL (io/fdc.c:201-215).
  task automatic read_cmd(input [7:0] op, input [7:0] ushd,
                          input [7:0] c, input [7:0] h, input [7:0] r,
                          input [7:0] nn, input [7:0] eot);
    begin
      wr8(3'd1, op);
      wr8(3'd1, ushd); wr8(3'd1, c); wr8(3'd1, h); wr8(3'd1, r);
      wr8(3'd1, nn); wr8(3'd1, eot); wr8(3'd1, 8'h1B); wr8(3'd1, 8'hFF);
    end
  endtask

  task automatic arm_dma(input integer bytes);
    begin
      dm_left = bytes[15:0]; dm_n = 0; dm_run = 1;
    end
  endtask

  // One drive's READ DATA of one 1024-byte sector (EOT = R, so the walk ends after it),
  // with the seven-byte result and the DMA count around it.
  task automatic read_one(input [1:0] us, input hd, input [7:0] c, input [7:0] h,
                          input [7:0] r, input [8*48-1:0] what);
    begin
      arm_dma(1024);
      read_cmd(8'h46, {5'd0, hd, us}, c, h, r, 8'h03, r);
      wait_irq(400000);
      get_result;
      expecti(g_rlen, 7, {what, ": result length"});
      expect8(g_rs[0], {5'd0, hd, us}, {what, ": ST0 = hd<<2|us"});
      expect8(g_rs[1], 8'h00, {what, ": ST1"});
      expect8(g_rs[2], 8'h00, {what, ": ST2"});
      // The count ends on R = EOT: C+1, R = 1, H unchanged, the machine's answer
      // (docs/probes/XE10T-XE10-FDC.TXT `X READ1 ... c=01 h=00 r=01` for C0 R1 EOT=1).
      expect8(g_rs[3], c + 8'd1, {what, ": C+1 at EOT"});
      expect8(g_rs[4], h, {what, ": H"});
      expect8(g_rs[5], 8'h01, {what, ": R = 1 at EOT"});
      expect8(g_rs[6], 8'h03, {what, ": N"});
      expecti(dm_n, 1024, {what, ": (N+1) bytes moved"});
    end
  endtask

  // THE READY-CHANGE INTERRUPT (NP2kai diskdrv.c): wait (bounded) for the interrupt, then
  // SENSE INTERRUPT STATUS must answer `st0` - AI|NR|drv for a change, AI|drv for a ready.
  task automatic expect_ai(input [7:0] st0, input integer maxc, input [8*64-1:0] what);
    begin
      wait_irq(maxc);
      wr8(3'd1, 8'h08);
      get_result;
      expecti(g_rlen, 2, {what, ": SENSE INT length"});
      expect8(g_rs[0], st0, {what, ": SENSE INT ST0"});
    end
  endtask

  // SENSE INTERRUPT STATUS until the empty answer (bounded), recording whether `want` came.
  reg drained_want;
  task automatic drain_sense(input [7:0] want);
    integer d;
    begin
      drained_want = 1'b0;
      for (d = 0; d < 8; d = d + 1) begin
        wr8(3'd1, 8'h08);
        get_result;
        if (g_rs[0] == want) drained_want = 1'b1;
        if (g_rs[0] == 8'h80) d = 8;
      end
    end
  endtask

  // A mount pulse on slot 1 (drive 0) or slot 2 (drive 1); `size` is the ONE hps_io
  // img_size both slots read, set immediately before the pulse as the framework does. The
  // insert is complete when NP2kai's two interrupts have come: the change, then the ready.
  task automatic mount0(input [63:0] size);
    begin
      img_size = size;
      @(negedge clk); mnt0 = 1;
      @(posedge clk);
      @(negedge clk); mnt0 = 0;
      expect_ai(8'hC8, 2000, "mount0: AI|NR|0 on the change");
      expect_ai(8'hC0, 40 * FRAME_CYC, "mount0: AI|0 after the insert delay");
    end
  endtask

  task automatic mount1(input [63:0] size);
    begin
      img_size = size;
      @(negedge clk); mnt1 = 1;
      @(posedge clk);
      @(negedge clk); mnt1 = 0;
      expect_ai(8'hC9, 2000, "mount1: AI|NR|1 on the change");
      expect_ai(8'hC1, 40 * FRAME_CYC, "mount1: AI|1 after the insert delay");
    end
  endtask


  // A mount pulse of `w` cycles (hps_io holds img_mounted for the whole image-selection
  // transaction, sys/hps_io.sv:334/:490), with no settle time after it: the caller decides
  // whether to wait for the walk.
  task automatic pulse_mount(input integer which, input [63:0] size, input integer w);
    begin
      img_size = size;
      @(negedge clk);
      if (which == 0) mnt0 = 1; else mnt1 = 1;
      repeat (w) @(negedge clk);
      mnt0 = 0; mnt1 = 0;
    end
  endtask

  // Wait (bounded) until drive `u`'s present bit reads `want`.
  task automatic wait_present(input integer u, input want, input integer maxc,
                              input [8*64-1:0] what);
    begin
      n = 0;
      while ((fdd_present[u] !== want) && (n < maxc)) begin @(negedge clk); n = n + 1; end
      if (fdd_present[u] !== want) begin
        $display("  FAIL: %0s: drive %0d present never became %0d", what, u, want);
        fails = fails + 1;
      end
    end
  endtask

  // SENSE DRIVE STATUS for unit `u` against `want` (NP2kai FDC_SenseDeviceStatus, io/fdc.c:274-312,
  // as tb_pc9821_fdd_two_units pins it: empty = TS|T0|us, with media = RDY|WP|TS|T0|us).
  task automatic st3_is(input [1:0] u, input [7:0] want, input [8*64-1:0] what);
    begin
      wr8(3'd1, 8'h04); wr8(3'd1, {6'd0, u});
      get_result;
      expecti(g_rlen, 1, {what, ": ST3 length"});
      expect8(g_rs[0], want, {what, ": ST3"});
    end
  endtask

  // A CHANGE UNDER A READ IS UNDEFINED; NOTHING MAY HANG. The guest that loses a command to an
  // eject times out and resets the controller (the DOR's bit-7 edge, NP2kai fdc_o94 ->
  // fdcstatusreset, io/fdc.c:1093-1104), so that is what this does after a bounded wait with the
  // DMA running again. Afterwards the controller must be idle, the change's AI|NR|drv must still
  // be there for SENSE INTERRUPT STATUS (fdcstatusreset does not touch fdc.stat), and - checked by
  // the caller - the medium must serve the next reads byte-exact. Whatever result, bytes or stall
  // the aborted command produced is NOT checked.
  task automatic recover_after_change(input [1:0] us, input [8*48-1:0] what);
    begin
      dm_pause_at = 32'h7FFFFFFF;
      repeat (3000) @(negedge clk);
      wr8(3'd2, 8'h80);                  // DOR bit 7 0->1: the controller reset
      wr8(3'd2, 8'h00);
      drain_sense(8'hC8 | {6'd0, us});
      if (!drained_want) begin
        $display("  FAIL: %0s: the change's AI|NR|drv was not reported", what);
        fails = fails + 1;
      end
      rd8(3'd0);
      expect8(rd_val, 8'h80, {what, ": MSR idle (RQM only) after the recovery"});
      dm_run = 0;
    end
  endtask

  // ==== STIMULUS ====
  integer k;
  integer parked, nbad;
  initial begin
    build_d88_a;
    build_d88_b;
    build_raw_c;

    reset = 1; repeat (6) @(negedge clk);
    reset = 0; repeat (4) @(negedge clk);

    // ---------------- M0: insert into EMPTY drives at runtime --------------------
    $display("PHASE M0 at %0t", $time);
    st3_is(2'd1, 8'h19, "M0 unit 1 empty before any insert");
    mount0(A_BYTES);
    mount1(B_BYTES);
    expecti(fdd_present, 2'b11, "M0 both drives present after a runtime insert");
    st3_is(2'd1, 8'h79, "M0 unit 1 RDY after its insert");
    read_one(2'd1, 1'b0, 8'h00, 8'h00, 8'h01, "M0 drive 1 R1");
    check_sector(1, 8'h01, 8'h00, 1024, 1024);

    // ---------------- M1: EJECT mid-DMA (channel 2), at several byte counts ----------
    $display("PHASE M1 at %0t", $time);
    // 1 byte in, 511 (the last byte of the first block), 512 (the block boundary: the next
    // fetch is the one the eject kills) and 1000. Each round re-inserts B first.
    for (k = 0; k < 4; k = k + 1) begin
      dm_pause_at = (k == 0) ? 1 : (k == 1) ? 511 : (k == 2) ? 512 : 1000;
      arm_dma(1024);
      read_cmd(8'h46, 8'h01, 8'h00, 8'h00, 8'h01, 8'h03, 8'h01);
      n = 0;
      while ((dm_n < dm_pause_at) && (n < 200000)) begin @(negedge clk); n = n + 1; end
    if (dm_n < dm_pause_at) $fatal(1, "TB_PC9821_FDD_MEDIA_CHANGE: the DMA never reached its park count");
      if (dm_n < dm_pause_at) $fatal(1, "TB_PC9821_FDD_MEDIA_CHANGE: the DMA never reached its park count");
      repeat (50) @(negedge clk);           // the DMA is parked, DRQ up
      expecti(dm_n, dm_pause_at, "M1 the DMA parked mid-sector");
      pulse_mount(1, 64'd0, 1);             // EJECT: a mount with img_size 0
      @(negedge clk);
      expecti(fdd_present[1], 0, "M1 READY drops on the eject edge");
      // recover_after_change re-opens the DMA (dm_pause_at), so the parked count is taken first:
      // a loop bounded by dm_pause_at after it ran to 2^31 (the OOM of 2026-10-08).
      parked = dm_pause_at;
      recover_after_change(2'd1, "M1 eject mid-DMA");
      nbad = 0;
      for (i = 0; i < parked; i = i + 1)
        if (dm_bytes[i] !== pb(8'h01, 8'h00, i)) begin
          if (nbad < 8)
            $display("  FAIL: M1 byte %0d before the eject is %02x, the image holds %02x",
                     i, dm_bytes[i], pb(8'h01, 8'h00, i));
          nbad = nbad + 1;
          fails = fails + 1;
        end
      st3_is(2'd1, 8'h19, "M1 ST3 unit 1 not ready after the eject");
      // Drive 0 is untouched by drive 1's eject.
      read_one(2'd0, 1'b0, 8'h00, 8'h00, 8'h02, "M1 drive 0 reads across drive 1's eject");
      check_sector(0, 8'h02, 8'h00, 1024, 1024);
      // Re-insert: READY rises again and the image reads byte-exact.
      mount1(B_BYTES);
      st3_is(2'd1, 8'h79, "M1 unit 1 RDY again after the re-insert");
      read_one(2'd1, 1'b0, 8'h00, 8'h00, 8'h01, "M1 drive 1 R1 after the re-insert");
      check_sector(1, 8'h01, 8'h00, 1024, 1024);
    end

    // ---------------- M2: EJECT before the first byte, and while the request is issued ----
    $display("PHASE M2 at %0t", $time);
    // dm_pause_at = 0: DRQ is up with nothing taken. Then an eject the cycle after the
    // command's last parameter byte - the request is still being handed to the medium.
    dm_pause_at = 0;
    arm_dma(1024);
    read_cmd(8'h46, 8'h01, 8'h00, 8'h00, 8'h01, 8'h03, 8'h01);
    n = 0;
    while (!dma_drq && (n < 200000)) begin @(negedge clk); n = n + 1; end
    if (!dma_drq) $fatal(1, "TB_PC9821_FDD_MEDIA_CHANGE: DRQ never rose");
    pulse_mount(1, 64'd0, 1);
    recover_after_change(2'd1, "M2 eject with DRQ up, 0 bytes");
    mount1(B_BYTES);
    arm_dma(1024);
    read_cmd(8'h46, 8'h01, 8'h00, 8'h00, 8'h02, 8'h03, 8'h02);
    pulse_mount(1, 64'd0, 1);
    recover_after_change(2'd1, "M2 eject while the request is issued");
    mount1(B_BYTES);

    // ---------------- M3: SWAP mid-DMA (remount with a different image) -------------
    $display("PHASE M3 at %0t", $time);
    // The read in flight ends with the change; the NEXT read answers the NEW image (raw C).
    dm_pause_at = 700;
    arm_dma(1024);
    read_cmd(8'h46, 8'h01, 8'h00, 8'h00, 8'h01, 8'h03, 8'h01);
    n = 0;
    while ((dm_n < dm_pause_at) && (n < 200000)) begin @(negedge clk); n = n + 1; end
    if (dm_n < dm_pause_at) $fatal(1, "TB_PC9821_FDD_MEDIA_CHANGE: the DMA never reached its park count");
    repeat (50) @(negedge clk);
    c_is_raw = 1;
    pulse_mount(1, C_BYTES, 1);
    @(negedge clk);
    expecti(fdd_present[1], 0, "M3 READY drops on the swap edge");
    recover_after_change(2'd1, "M3 swap mid-DMA");
    wait_present(1, 1'b1, 20000, "M3 READY rises once the new image has parsed");
    expect_ai(8'hC1, 40 * FRAME_CYC, "M3 AI|1 once the swapped-in image is ready");
    read_one(2'd1, 1'b0, 8'h00, 8'h00, 8'h01, "M3 drive 1 reads the NEW image");
    check_sector(2, 8'h01, 8'h00, 1024, 1024);

    // ---------------- M4: a mount on the OTHER drive while a read is in flight -----------
    $display("PHASE M4 at %0t", $time);
    // Drive 0 is mid-DMA; drive 1 is swapped back to B. Drive 1's READY drops at once (its
    // walk waits for the engine), drive 0's read finishes with drive 0's own bytes.
    dm_pause_at = 300;
    arm_dma(1024);
    read_cmd(8'h46, 8'h00, 8'h00, 8'h00, 8'h01, 8'h03, 8'h01);
    n = 0;
    while ((dm_n < dm_pause_at) && (n < 200000)) begin @(negedge clk); n = n + 1; end
    if (dm_n < dm_pause_at) $fatal(1, "TB_PC9821_FDD_MEDIA_CHANGE: the DMA never reached its park count");
    repeat (50) @(negedge clk);
    c_is_raw = 0;
    pulse_mount(1, B_BYTES, 1);
    @(negedge clk);
    expecti(fdd_present[1], 0, "M4 drive 1 READY drops on its own mount edge");
    expecti(fdd_present[0], 1, "M4 drive 0 READY untouched by drive 1's mount");
    dm_pause_at = 32'h7FFFFFFF;
    // Drive 1's change interrupts NOW (AI|NR|1 is pending), so the read's end is found by its
    // byte count, not by the interrupt line.
    n = 0;
    while ((dm_n < 1024) && (n < 400000)) begin @(negedge clk); n = n + 1; end
    repeat (50) @(negedge clk);
    get_result;
    expecti(g_rlen, 7, "M4 drive 0 result length");
    expect8(g_rs[0], 8'h00, "M4 drive 0 ST0 = success");
    expect8(g_rs[5], 8'h01, "M4 drive 0 R = 1 at EOT (XE10T-XE10-FDC READ1)");
    expecti(dm_n, 1024, "M4 drive 0 moved its whole sector");
    check_sector(0, 8'h01, 8'h00, 1024, 1024);
    wr8(3'd1, 8'h08); get_result;
    expect8(g_rs[0], 8'hC9, "M4 drive 1's change reported AI|NR|1 meanwhile");
    wait_present(1, 1'b1, 20000, "M4 drive 1 READY rises after its deferred walk");
    expect_ai(8'hC1, 40 * FRAME_CYC, "M4 AI|1 once drive 1 is ready");
    read_one(2'd1, 1'b0, 8'h00, 8'h00, 8'h02, "M4 drive 1 reads B after the swap back");
    check_sector(1, 8'h02, 8'h00, 512, 1024);

    // ---------------- M5: back-to-back mounts - the LAST one is the medium ----------
    $display("PHASE M5 at %0t", $time);
    c_is_raw = 1;
    pulse_mount(1, C_BYTES, 1);
    repeat (2) @(negedge clk);
    c_is_raw = 0;
    pulse_mount(1, B_BYTES, 1);
    wait_present(1, 1'b1, 20000, "M5 drive 1 READY after two back-to-back mounts");
    expect_ai(8'hC9, 2000, "M5 AI|NR|1 (two changes, one status slot)");
    expect_ai(8'hC1, 40 * FRAME_CYC, "M5 AI|1 once, after the LAST change's delay");
    read_one(2'd1, 1'b1, 8'h00, 8'h01, 8'h03, "M5 drive 1 answers B (the last mount)");
    check_sector(1, 8'h03, 8'h01, 1024, 1024);

    // ---------------- M6: remount of the SAME image, with a held mount level -------
    $display("PHASE M6 at %0t", $time);
    // A 40-cycle level is one media change: READY drops, rises once, the image reads.
    pulse_mount(1, B_BYTES, 40);
    expecti(fdd_present[1], 0, "M6 READY is down while the held mount is being taken");
    wait_present(1, 1'b1, 20000, "M6 READY rises after the remount of the same image");
    expect_ai(8'hC9, 2000, "M6 one AI|NR|1 for the held level");
    expect_ai(8'hC1, 40 * FRAME_CYC, "M6 one AI|1");
    wr8(3'd1, 8'h08); get_result;
    expect8(g_rs[0], 8'h80, "M6 nothing else pending: the held level was ONE change");
    read_one(2'd1, 1'b0, 8'h00, 8'h00, 8'h01, "M6 drive 1 R1 after the same-image remount");
    check_sector(1, 8'h01, 8'h00, 1024, 1024);

    // ---------------- M7: THE STALE-BLOCK GUARD, across drives ----------------------
    $display("PHASE M7 at %0t", $time);
    // A read ending at a block boundary leaves the medium's read-ahead of the NEXT block in flight
    // (consume() asks for it at the wrap). Drive 1 (RAW C) reads R1 = blocks 0-1, so its
    // read-ahead is block 2 of slot C; drive 0 (RAW C^0x5A) then reads R2, whose FIRST block is
    // block 2 of slot B - the same index, accepted while slot C's fetch is still outstanding.
    // That completion is drive 1's image; served to drive 0 it would read as C, not C^0x5A.
    // Expected bytes are the images' own (check_sector), so this decides whether the guard
    // (`bstale`, set when a request is accepted over an outstanding fetch) is load-bearing.
    b_is_raw = 1;
    mount0(C_BYTES);
    c_is_raw = 1;
    mount1(C_BYTES);
    read_one(2'd1, 1'b0, 8'h00, 8'h00, 8'h01, "M7 drive 1 R1 (blocks 0-1)");
    check_sector(2, 8'h01, 8'h00, 1024, 1024);
    read_one(2'd0, 1'b0, 8'h00, 8'h00, 8'h02, "M7 drive 0 R2 (block 2) over drive 1's read-ahead");
    check_sector(3, 8'h02, 8'h00, 1024, 1024);

    // ==== VERDICT ====
    if (fails == 0) begin
      $display("TB_PC9821_FDD_MEDIA_CHANGE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_FDD_MEDIA_CHANGE: FAIL (%0d errors)", fails);
  end

endmodule
