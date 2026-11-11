`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// pc9821_fdd_media serves TWO drives with per-drive state behind one shared engine, and the real pc9821_fdc reaches both through it: with a different D88 mounted in each of the two hps_io slots, a READ DATA command on unit 1 returns FDD1's own sector bytes and a command on unit 0 still returns FDD0's, each drive's D88 track table and stored sector sizes are its own (a sector at (C,H) answers the requesting drive's image, so seeking one drive leaves the other's position alone and a one-header track answers an ordinal the other drive's image does not have), a drive remounted with a RAW image answers from that image while the other keeps serving its D88, and an unmounted or ejected drive 1 keeps the controller's existing no-media answer (the deferred completion: ST0 IC0|NR|unit 1 through SENSE INTERRUPT STATUS, no result phase, no byte moved).
//
// THE SHAPE OF THE DEFECT THIS IS AIMED AT. Two drives on one engine invites exactly one
// class of bug: state that is per drive in the machine and single in the RTL. Every arm
// below is chosen so a SHARED copy of one of those answers the WRONG bytes rather than no
// bytes: the two D88s put track 1 at different file offsets (0x8D0 vs 0xAD0), give the same
// (C,H,R) different stored sizes (1024 vs 512+zeros) and hold different data patterns, and
// both images are smaller than the shared block adapter's 8-sector read-ahead window - so a
// stale window or a table indexed without the drive serves the other drive's block and is
// caught by a byte compare rather than by a timeout. The mutations this bench was checked
// against (a table addressed without the drive, a present bit shared, a parsed size shared)
// were each caught by a case here.
//
// WHAT IS DRIVEN, AND WHY THE REAL CONTROLLER IS IN THE LOOP. The unit select is the
// CONTROLLER's (NP2kai get_hdus: `fdc.us = fdc.cmds[0] & 3`, io/fdc.c:201-215) and so is the
// no-media decision (`media_present[us]`, FDC_DriveCheck :175-193), so a bench at the sector
// seam alone could not show that selecting drive 1 on the OSD reaches a second image. This
// one writes the 9-byte commands into the real pc9821_fdc and takes the bytes off the real
// DMA handshake, over the real pc9821_fdd_media and the real pc9821_block_share (slot A
// unmounted): the whole path, drive select included.
//
// EXPECTED VISIBLE ANSWERS, from the references:
//   * READ DATA's seven-byte result {ST0,ST1,ST2,C,H,R,N} with ST0 = us|hd<<2
//     (fdcsend_success7, io/fdc.c:120-158); a one-sector read with EOT = R ended by the DMA's
//     terminal count answers C+1 and R = 1, the real Xe10's answer
//     (docs/probes/XE10T-XE10-FDC.TXT READ1), where NP2kai keeps C (fdc_dataread :1016-1026).
//   * a drive with no medium: no result phase (MSR & 0xC0 == 0x80) and ST0 = IC0|NR|us =
//     0x49 for unit 1 through SENSE INTERRUPT STATUS, which is the probe subset's deferred
//     answer and why `media_present` is part of the controller's contract (:175-193).
//   * SENSE DRIVE STATUS: unit 1 empty = TS|T0|us = 0x19, unit 0 with media = RDY|WP|TS|T0
//     = 0x78 (NP2kai FDC_SenseDeviceStatus :274-312; qemu pc98-fdc.c:2234 agrees).
//   * READ ID answers the crcn-th header of the TRACK REGISTER's track with R/N from the
//     header and the track's own sector count (fdd_readid_d88 :494-552).
//   * each drive's sector bytes are the ones THIS bench wrote into ITS image; the D88 layout
//     and the sector walk are the ones tb_pc9821_fdd_media_d88 pins against NP2kai's own
//     readers (diskimage/fd/fdd_d88.c:220-258, :427-443).
//
// THE HOST SIDE is a model of the MiSTer block reader for BOTH slots: one word per clk at
// sd_buff_addr, sd_ack held for the handshake, (sd_blk_cnt+1) sectors per handshake, and
// whichever slot's request is presented is answered from THAT slot's image - which is what
// makes a wrong-slot fetch a byte mismatch rather than an infinite wait.
//
// ==== DUT ====
`define IMGMAX 1310720

module tb_pc9821_fdd_two_units;

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
      // No media-change tag: this bench's mounts are not ready changes (pc9821_fdc's media_chg).
      .media_chg(4'd0), .frame_tick(1'b0),
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
      .present(fdd_present), .writeprotect(fdd_wp),
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
      else                    v = {imgC[base + 1], imgC[base]};
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
        hwhich   <= 2'd0;
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
  reg [15:0] dm_left;
  reg        dm_run;
  integer    dm_n;
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
    end else if (dm_run && dma_drq && (dm_left != 16'd0)) begin
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
    #600_000_000;   // three READ IDs may each wait up to a revolution (RID_WAIT)
    $fatal(1, "TB_PC9821_FDD_TWO_UNITS: watchdog timeout (no verdict reached)");
  end

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
    begin
      for (i = 0; i < nb; i = i + 1) begin
        if (which == 0)      want = pa(r, hh, i);
        else if (which == 1) want = (i < stored) ? pb(r, hh, i) : 8'h00;
        else                 want = praw((({15'd0, hh} * 16'd8) + {15'd0, r} - 16'd1) * 16'd1024
                                         + i);
        if (dm_bytes[i] !== want) begin
          $display("  FAIL: image %0d sector (H=%0d,R=%0d) byte %0d is %02x, that image holds %02x",
                   which, hh, r, i, dm_bytes[i], want);
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

  // A READ ID answers when its ID field has passed the head, one sector period of the track
  // after the command (pc9821_fdc X_IDW; tb_pc9821_fdc_readid_wait pins it): a one-header track
  // waits a whole revolution, up to 1/5 s of the module default's 50 MHz, plus slack.
  localparam integer RID_WAIT = 50_000_000 / 5 + 100_000;
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

  // THE HEAD IS WHERE THE LAST SEEK LEFT IT. NP2kai reads a sector on the physical track
  // (treg << 1) + hd and only matches the command's C against the header (fdd_d88.c
  // searchsector_d88; READ/WRITE DATA replace treg with C only while it differs from the last
  // SEEK's, io/fdc.c fdc_lasttreg), so - as the BIOS does - a data command for another
  // cylinder is preceded by a SEEK there. The bench seeks only when the drive's track register
  // is not already on the command's C, so every case keeps its own command stream otherwise.
  task automatic seek_to(input [1:0] u, input [7:0] c);
    begin
      if (fdd_present[u[0]] && (u[1] == 1'b0) && (fdc.treg[u] != c)) begin
        wr8(3'd1, 8'h0F); wr8(3'd1, {6'd0, u}); wr8(3'd1, c);
        wait_irq(400000);
        wr8(3'd1, 8'h08);   // SENSE INTERRUPT STATUS: drain the seek's completion
        get_result;
      end
    end
  endtask

  // READ DATA: opcode, then us|hd<<2, C, H, R, N, EOT, GPL, DTL (io/fdc.c:201-215).
  task automatic read_cmd(input [7:0] op, input [7:0] ushd,
                          input [7:0] c, input [7:0] h, input [7:0] r,
                          input [7:0] nn, input [7:0] eot);
    begin
      seek_to(ushd[1:0], c);
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

  // A mount pulse on slot 1 (drive 0) or slot 2 (drive 1); `size` is the ONE hps_io
  // img_size both slots read, set immediately before the pulse as the framework does.
  task automatic mount0(input [63:0] size);
    begin
      img_size = size;
      @(negedge clk); mnt0 = 1;
      @(posedge clk);
      @(negedge clk); mnt0 = 0;
      repeat (4000) @(negedge clk);
    end
  endtask

  task automatic mount1(input [63:0] size);
    begin
      img_size = size;
      @(negedge clk); mnt1 = 1;
      @(posedge clk);
      @(negedge clk); mnt1 = 0;
      repeat (4000) @(negedge clk);
    end
  endtask

  // ==== STIMULUS ====
  initial begin
    build_d88_a;
    build_d88_b;
    build_raw_c;

    reset = 1; repeat (6) @(negedge clk);
    reset = 0; repeat (4) @(negedge clk);

    // ---------------- U1: only drive 0 is mounted; drive 1 has NO medium ----------
    // Both drives are EQUIPPED (the machine has two, pc9821_fdc's FDD_DRIVES = 2), so the
    // discriminator here is presence: drive 1's READ DATA must take the probe subset's
    // deferred answer (no result phase, ST0 IC0|NR|unit 1) and move no byte, while drive 0
    // reads its own image.
    mount0(A_BYTES);
    expecti(fdd_present, 2'b01, "U1 only drive 0 is present");
    read_one(2'd0, 1'b0, 8'h00, 8'h00, 8'h01, "U1 drive 0 R1");
    check_sector(0, 8'h01, 8'h00, 1024, 1024);

    arm_dma(1024);
    read_cmd(8'h46, 8'h01, 8'h00, 8'h00, 8'h01, 8'h03, 8'h01);   // unit 1
    wait_irq(200000);
    // The not-ready answer is its own seven-byte result with the interrupt, and SENSE
    // INTERRUPT STATUS then has nothing: the real Xe10's empty-drive READ DATA
    // (docs/probes/XE10T-XE10-FDC2A.TXT `NRRD da=91 ... sis=80 dmacnt=03FF nres=7 st0=49`).
    get_result;
    expecti(g_rlen, 7, "U1 a drive with no medium answers a seven-byte result (NRRD nres=7)");
    expect8(g_rs[0], 8'h49, "U1 ST0 = IC0|NR|unit 1 (NRRD st0=49)");
    wr8(3'd1, 8'h08);                                            // SENSE INTERRUPT STATUS
    get_result;
    expect8(g_rs[0], 8'h80, "U1 SENSE INTERRUPT STATUS then answers 80 (NRRD sis=80)");
    expecti(dm_n, 0, "U1 no byte moves without media");

    // SENSE DRIVE STATUS answers its one byte in the RESULT PHASE and raises NO interrupt
    // at all (NP2kai FDC_SenseDeviceStatus, io/fdc.c:274-312: it sets the drive's busy bit
    // and builds ST3, with no fdcsend_*/intreq on that path), so this arm reads the result
    // directly. Unit 1 is equipped but EMPTY (TS|T0|us, no RDY); unit 0 has media
    // (RDY|WP|TS|T0).
    wr8(3'd1, 8'h04); wr8(3'd1, 8'h01);
    get_result;
    expecti(g_rlen, 1, "U1 ST3 result length");
    expect8(g_rs[0], 8'h19, "U1 ST3 unit 1 = TS|T0|us, no RDY (no medium)");
    wr8(3'd1, 8'h04); wr8(3'd1, 8'h00);
    get_result;
    expecti(g_rlen, 1, "U1 ST3 unit 0 result length");
    expect8(g_rs[0], 8'h78, "U1 ST3 unit 0 = RDY|WP|TS|T0 (medium mounted)");

    // ---------------- U2: THE DECISIVE ONE - two different images, alternating -----
    // A different D88 goes into FDD1's slot. Every read below alternates drives, so a
    // shared medium state (one track table, one present bit, one parsed sector size)
    // answers the other drive's bytes instead of failing loudly.
    build_d88_b;
    mount1(B_BYTES);
    expecti(fdd_present, 2'b11, "U2 both drives are present");

    // media_present[1] really follows FDD1's mount, read back through the controller: ST3
    // for unit 1 with media is RDY|WP|TS|T0|us (NP2kai :274-312).
    wr8(3'd1, 8'h04); wr8(3'd1, 8'h01);
    get_result;
    expect8(g_rs[0], 8'h79, "U2 ST3 unit 1 = RDY|WP|TS|T0|us once ITS slot is mounted");

    read_one(2'd1, 1'b0, 8'h00, 8'h00, 8'h01, "U2 drive 1 R1");
    check_sector(1, 8'h01, 8'h00, 1024, 1024);
    read_one(2'd0, 1'b0, 8'h00, 8'h00, 8'h01, "U2 drive 0 R1");
    check_sector(0, 8'h01, 8'h00, 1024, 1024);
    read_one(2'd1, 1'b0, 8'h00, 8'h00, 8'h02, "U2 drive 1 R2");
    // FDD1's R2 stores only 512 bytes, so the rest of the 1024-byte read is ZEROES
    // (fdd_read_d88 :427-443) - a per-drive STORED SIZE, not just a per-drive pattern.
    check_sector(1, 8'h02, 8'h00, 512, 1024);
    read_one(2'd0, 1'b0, 8'h00, 8'h00, 8'h02, "U2 drive 0 R2");
    check_sector(0, 8'h02, 8'h00, 1024, 1024);
    // ... and back to drive 1 a third time, so the engine has been handed over twice.
    read_one(2'd1, 1'b0, 8'h00, 8'h00, 8'h01, "U2 drive 1 R1 again");
    check_sector(1, 8'h01, 8'h00, 1024, 1024);

    // ---------------- U3: TRACK INDEPENDENCE -------------------------------------
    // A real second drive has its own head position. Here the position is the controller's
    // per-drive track register plus each image's OWN track table: drive 1 at (C=0,H=1) must
    // answer FDD1's track 1 and drive 0 left at (C=0,H=0) must still answer FDD0's track 0.
    // The two images put track 1 at different file offsets (0x8D0 and 0xAD0), so one table
    // cannot answer both.
    read_one(2'd1, 1'b1, 8'h00, 8'h01, 8'h01, "U3 drive 1 track 1 R1");
    check_sector(1, 8'h01, 8'h01, 1024, 1024);
    read_one(2'd0, 1'b0, 8'h00, 8'h00, 8'h01, "U3 drive 0 still on track 0");
    check_sector(0, 8'h01, 8'h00, 1024, 1024);
    // READ ID walks the TRACK REGISTER's track in the requesting drive's image: FDD1's
    // track 1 has TWO headers (R1 then R3) and FDD0's has ONE, so the second READ ID's R=3
    // can only come from FDD1's own table (fdd_readid_d88 :494-552, crcn :513-518).
    wr8(3'd1, 8'h4A); wr8(3'd1, 8'h05);     // READ ID, unit 1, hd 1
    wait_irq(RID_WAIT);
    get_result;
    expecti(g_rlen, 7, "U3 READ ID result length");
    expect8(g_rs[0], 8'h05, "U3 READ ID ST0 = hd<<2|us = 4|1");
    expect8(g_rs[3], 8'h00, "U3 READ ID C = the drive's track register");
    expect8(g_rs[4], 8'h01, "U3 READ ID H = the head");
    expect8(g_rs[5], 8'h01, "U3 READ ID R = header 1");
    expect8(g_rs[6], 8'h03, "U3 READ ID N");
    wr8(3'd1, 8'h4A); wr8(3'd1, 8'h05);     // READ ID again: crcn advances
    wait_irq(RID_WAIT);
    get_result;
    expect8(g_rs[5], 8'h03, "U3 READ ID R = FDD1's second header (R3, which FDD0's track 1 does not have)");
    expect8(g_rs[6], 8'h03, "U3 READ ID N of the second header");
    wr8(3'd1, 8'h4A); wr8(3'd1, 8'h00);     // READ ID, unit 0, hd 0: crcn wrapped
    wait_irq(RID_WAIT);
    get_result;
    expect8(g_rs[0], 8'h00, "U3 READ ID unit 0 ST0 = hd<<2|us");
    expect8(g_rs[4], 8'h00, "U3 READ ID unit 0 H = its own head");
    expect8(g_rs[5], 8'h01, "U3 READ ID unit 0 R = header 1 of ITS track 0");
    expect8(g_rs[6], 8'h03, "U3 READ ID unit 0 N");

    // ---------------- U3H: DRIVE 1 ABOVE TRACK 71 - the range the array did not cover ----
    // P1-a. The shared track table is addressed {drive, track} - NINE bits, drive 1 at
    // 256..419 - but was declared with only 328 entries, so drive 1 at track >= 72 read and
    // wrote OUTSIDE the array. THIS IS THE GAP THIS BENCH USED TO HAVE: every drive-1 read
    // above is at track 0 or 1 (indices 256/257, both in range), so the pre-change bench
    // passed with the upper half of every drive-1 2HD image unreadable. Track index is
    // (C<<1)|H, so C=36 is track 72 (the FIRST out-of-range index) and C=72 is track 144.
    // PRE-CHANGE: present, but the walk's write at index {1,72} was dropped and seek_off read
    // 0 - the requests below answered err (ST0 IC0, ST1 ND) instead of the sector bytes.
    read_one(2'd1, 1'b0, 8'h24, 8'h00, 8'h01, "U3H drive 1 track 72 (C=36) R1");
    check_sector(1, 8'h24, 8'h00, 1024, 1024);
    read_one(2'd1, 1'b0, 8'h48, 8'h00, 8'h01, "U3H drive 1 track 144 (C=72) R1");
    check_sector(1, 8'h48, 8'h00, 1024, 1024);
    // Drive 0 is untouched by the widening: its low tracks still answer their own bytes.
    read_one(2'd0, 1'b0, 8'h00, 8'h00, 8'h01, "U3H drive 0 still on track 0");
    check_sector(0, 8'h01, 8'h00, 1024, 1024);

    // ---------------- U4: a REMOUNT of drive 1 moves only drive 1 -----------------
    // The second drive's slot takes a RAW image (a different FORMAT and a different size),
    // which changes drive 1's geometry and leaves drive 0's parsed D88 alone - the per-drive
    // state is the parsed format and extent, not only the bytes.
    build_raw_c;
    c_is_raw = 1;
    mount1(C_BYTES);
    expecti(fdd_present, 2'b11, "U4 drive 1 present after the RAW remount");
    read_one(2'd1, 1'b0, 8'h00, 8'h00, 8'h01, "U4 drive 1 RAW R1");
    check_sector(2, 8'h01, 8'h00, 1024, 1024);
    read_one(2'd0, 1'b0, 8'h00, 8'h00, 8'h02, "U4 drive 0 still its D88");
    check_sector(0, 8'h02, 8'h00, 1024, 1024);
    read_one(2'd1, 1'b1, 8'h00, 8'h01, 8'h01, "U4 drive 1 RAW track 1");
    check_sector(2, 8'h01, 8'h01, 1024, 1024);

    // ---------------- U5: EJECT drive 1; drive 0 keeps reading --------------------
    mount1(64'd16);                          // a sub-sector mount is an eject
    expecti(fdd_present, 2'b01, "U5 the ejected drive 1 is not present");
    arm_dma(1024);
    read_cmd(8'h46, 8'h01, 8'h00, 8'h00, 8'h01, 8'h03, 8'h01);
    wait_irq(200000);
    get_result;
    expecti(g_rlen, 7, "U5 the ejected drive answers a seven-byte result (NRRD nres=7)");
    expect8(g_rs[0], 8'h49, "U5 ST0 = IC0|NR|unit 1 after the eject (NRRD st0=49)");
    expecti(dm_n, 0, "U5 no byte moves from an ejected drive");
    read_one(2'd0, 1'b0, 8'h00, 8'h00, 8'h01, "U5 drive 0 unaffected by the eject");
    check_sector(0, 8'h01, 8'h00, 1024, 1024);

    // ==== VERDICT ====
    if (fails == 0) begin
      $display("TB_PC9821_FDD_TWO_UNITS: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_FDD_TWO_UNITS: FAIL (%0d errors)", fails);
  end

endmodule
