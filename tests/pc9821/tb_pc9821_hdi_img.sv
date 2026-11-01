// tb_pc9821_hdi_img - HDI (Anex86/FDI) hard-disk images through the real disk path.
//
// ==== WHAT THIS PROVES ====
// TB_PC9821_HDI_IMG: An HDI (Anex86/FDI, 4096-byte front header: reserved 0, HeaderSize 4096, DataSize 34816, 512 bytes/sector, 17/2/2 geometry) and a fixed VHD (Microsoft Virtual PC: the same 68 payload sectors at offset 0 plus a 512-byte big-endian 'conectix' footer whose current size is 34816) both mount on the real pc9821_ata -> pc9821_hdd_image -> pc9821_block_share stack as drives whose IDENTIFY pages and every guest READ SECTORS sector are IDENTICAL to the same 68 sectors mounted raw, with capacity cylinders x heads x sectors for HDI (NP2kai fdd/sxsihdd.c totals; the file is 76 sectors), every guest LBA translated by HeaderSize/512 for reads AND writes (a write of guest LBA 5 lands at file LBA 13 and the header bytes 0..4095 are never read or written as guest data), capacity current size/512 for VHD (the file is 69 sectors), offset 0 there (a write of guest LBA 5 lands at file LBA 5, and the footer's sector 68 is refused by the drive and never exposed), the drive held not-ready until the mount probes have read sector 0 and, for VHD, the last sector through the block port with the read-ahead window tag low, a queued guest request served after the probes with its offset, a remount during a probe discarding that probe and re-reading, an eject clearing the offset, a raw PC-98 image (first DWORD the IPL, not 0) NOT detected as either, and every header NP2kai's reader refuses (heads 0, heads 256) or this ATA cannot serve (bytes/sector 256), or that content detection cannot tell from a raw disk (reserved != 0, HeaderSize < 32, HeaderSize not a multiple of 512), and every corrupt VHD footer (bad cookie, bad checksum, disk type 3 with a cxsparse header at offset 512, current size with no room for the footer, data offset not all-ones) falling back to the raw image byte for byte; while the headers NP2kai mounts although the file is not exactly header + DataSize (a DataSize that disagrees, a geometry past the file or short of DataSize, trailing padding) mount as HDI with the header's offset and NP2kai's capacity, cylinders x heads x sectors clamped to the sectors the file holds after the header.
//
// Reference: https://www.pc98.org/project/doc/hdi.html (the header's eight little-endian
// DWORDs), NP2kai fdd/sxsihdd.h (`HDIHDR`: dummy, hddtype, headersize, hddsize, sectorsize,
// sectors, surfaces, cylinders) and fdd/sxsihdd.c (every access at `pos * size + headersize`;
// geometry bounds `surfaces >= 256`, `cylinders >= 65536`, `sectors >= 256` rejected).
// The payload bytes are a function of the payload offset, so an expected sector is never read
// out of this core's own RTL.

`timescale 1ns / 1ps

module tb_pc9821_hdi_img;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  integer errors = 0;

  // ==== the image ====
  // 68 sectors of payload: 512 * 17 * 2 * 2 = 34816 bytes. The HDI file is that plus a
  // 4096-byte header (76 sectors), so an HDI mount and a raw mount differ in capacity if the
  // detector does not subtract the header.
  localparam integer SEC_BYTES  = 512;
  localparam integer DATA_SECT  = 68;
  localparam integer DATA_BYTES = DATA_SECT * SEC_BYTES;   // 34816
  localparam integer HDR_BYTES  = 4096;
  localparam integer HDI_BYTES  = HDR_BYTES + DATA_BYTES;  // 38912
  localparam integer HOST_MAX   = 65536;
  localparam [31:0]  CAP_DATA   = 32'd68;
  localparam [31:0]  CAP_RAW_HDI = 32'd76;
  localparam integer VHD_BYTES   = DATA_BYTES + 512;       // 35328, a 512-byte footer at the end
  localparam [31:0]  CAP_RAW_VHD = 32'd69;
  localparam integer PAD_BYTES   = 4096;   // variant 7: trailing padding after the payload

  // NP2kai's HDI capacity (fdd/sxsihdd.c: `totals = (FILEPOS)cylinders * sectors *
  // surfaces;`, DataSize never read), clamped to the sectors the file holds after the header
  // (this core's rule: no guest LBA past the file).
  function automatic [31:0] np2_hdi_cap(input integer file_bytes);
    integer t, f;
    begin
      t = hf[5] * hf[6] * hf[7];
      f = (file_bytes - hf[2]) / SEC_BYTES;
      np2_hdi_cap = (t < f) ? t : f;
    end
  endfunction

  // One byte of payload: every offset names a different byte, and offset 0 is 0x5A so a raw
  // image's first DWORD is nonzero (an IPL, not an HDI header).
  function automatic [7:0] pbyte(input integer off);
    begin
      pbyte = 8'((off * 7 + (off >> 8) * 3 + 8'h5A) & 8'hFF);
    end
  endfunction

  function automatic [15:0] pword(input integer sec, input integer w);
    begin
      pword = {pbyte(sec * SEC_BYTES + 2 * w + 1), pbyte(sec * SEC_BYTES + 2 * w)};
    end
  endfunction

  reg [7:0] host_img [0:HOST_MAX-1];
  reg [7:0] vfoot [0:511];
  integer   host_bytes;
  integer   k;

  // The header DWORDs, little-endian: reserved, type/MB, HeaderSize, DataSize,
  // bytes/sector, sectors/track, heads, cylinders.
  reg [31:0] hf [0:7];
  task automatic hdr_defaults;
    begin
      hf[0] = 32'd0;
      hf[1] = 32'd32;        // capacity in MB (a hint; never tested)
      hf[2] = 32'd4096;
      hf[3] = DATA_BYTES;
      hf[4] = 32'd512;
      hf[5] = 32'd17;
      hf[6] = 32'd2;
      hf[7] = 32'd2;
    end
  endtask

  task automatic put_dword(input integer addr, input [31:0] v);
    begin
      host_img[addr + 0] = v[7:0];
      host_img[addr + 1] = v[15:8];
      host_img[addr + 2] = v[23:16];
      host_img[addr + 3] = v[31:24];
    end
  endtask

  // The file stays the same shape (4096-byte header area, then payload); only the header's
  // fields change, so every corrupt variant is the SAME bytes with one field broken.
  task automatic build_image(input integer variant);
    integer i;
    begin
      hdr_defaults;
      case (variant)
        1: hf[0] = 32'd1;                       // reserved != 0
        2: hf[3] = DATA_BYTES + 512;            // DataSize does not add up to the file size
        3: hf[7] = 32'd3;                       // geometry (102 sectors) past the file's 68
        4: begin hf[2] = 32'd16; hf[3] = HDI_BYTES - 16; end   // HeaderSize < 32
        5: begin hf[2] = 32'd4097; hf[3] = HDI_BYTES - 4097; end // not a sector multiple
        6: hf[4] = 32'd256;                     // bytes/sector != the ATA's 512
        7: ;                                    // exact header, file padded (PAD_BYTES below)
        8: hf[7] = 32'd1;                       // geometry (34 sectors) short of DataSize
        9: hf[6] = 32'd0;                       // heads 0 (NP2kai: surfaces == 0)
        10: hf[6] = 32'd256;                    // heads 256 (NP2kai: surfaces >= 256)
        default: ;                              // 0 = a valid HDI
      endcase
      for (i = 0; i < HOST_MAX; i = i + 1) host_img[i] = 8'h00;
      for (i = 0; i < 8; i = i + 1) put_dword(i * 4, hf[i]);
      for (i = 0; i < DATA_BYTES; i = i + 1) host_img[HDR_BYTES + i] = pbyte(i);
    end
  endtask

  task automatic build_raw;
    integer i;
    begin
      for (i = 0; i < HOST_MAX; i = i + 1) host_img[i] = 8'h00;
      for (i = 0; i < DATA_BYTES; i = i + 1) host_img[i] = pbyte(i);
    end
  endtask

  // ---- fixed VHD: a 512-byte big-endian footer at the end of the file ----
  task automatic be32(input integer a, input [31:0] v);
    begin
      vfoot[a + 0] = v[31:24];
      vfoot[a + 1] = v[23:16];
      vfoot[a + 2] = v[15:8];
      vfoot[a + 3] = v[7:0];
    end
  endtask

  task automatic be64(input integer a, input [63:0] v);
    begin
      be32(a, v[63:32]);
      be32(a + 4, v[31:0]);
    end
  endtask

  // variant 0 = a valid fixed VHD; 1 bad cookie; 2 bad checksum; 3 dynamic (type 3 +
  // "cxsparse" at offset 512); 4 current size leaves no room for the footer; 5 data offset
  // is not the fixed disk's all-ones.
  task automatic build_vhd(input integer variant);
    integer i;
    reg [31:0] sum;
    begin
      for (i = 0; i < HOST_MAX; i = i + 1) host_img[i] = 8'h00;
      for (i = 0; i < DATA_BYTES; i = i + 1) host_img[i] = pbyte(i);
      for (i = 0; i < 512; i = i + 1) vfoot[i] = 8'h00;
      // cookie "conectix" (bytes, in order)
      vfoot[0] = 8'h63; vfoot[1] = 8'h6F; vfoot[2] = 8'h6E; vfoot[3] = 8'h65;
      vfoot[4] = 8'h63; vfoot[5] = 8'h74; vfoot[6] = 8'h69; vfoot[7] = 8'h78;
      be32(8,  32'h0000_0002);              // features
      be32(12, 32'h0001_0000);              // file format version
      be64(16, 64'hFFFF_FFFF_FFFF_FFFF);    // data offset: fixed
      be32(24, 32'h0000_0000);              // timestamp
      vfoot[28] = "q"; vfoot[29] = "e"; vfoot[30] = "m"; vfoot[31] = "u";   // creator app
      be32(32, 32'h0005_0003);              // creator version
      vfoot[36] = "W"; vfoot[37] = "i"; vfoot[38] = "2"; vfoot[39] = "K";   // creator host OS
      be64(40, 64'(DATA_BYTES));            // original size
      be64(48, 64'(DATA_BYTES));            // current size
      be32(56, {16'd2, 8'd2, 8'd17});       // geometry: 2 cylinders, 2 heads, 17 sectors
      be32(60, 32'd2);                      // disk type: fixed
      case (variant)
        1: vfoot[0] = 8'h43;                         // 'C': bad cookie
        3: begin
             be32(60, 32'd3);                        // dynamic: unsupported
             // the dynamic image's own "cxsparse" header sits at offset 512
             host_img[512 + 0] = "c"; host_img[512 + 1] = "x"; host_img[512 + 2] = "s";
             host_img[512 + 3] = "p"; host_img[512 + 4] = "a"; host_img[512 + 5] = "r";
             host_img[512 + 6] = "s"; host_img[512 + 7] = "e";
           end
        4: be64(48, 64'(VHD_BYTES));         // current size == the file: no footer room
        5: be64(16, 64'd0);                  // not the fixed disk's all-ones data offset
        default: ;
      endcase
      // checksum: one's complement of the sum of all 512 bytes with bytes 64..67 zero
      sum = 32'd0;
      for (i = 0; i < 512; i = i + 1)
        if (i < 64 || i > 67) sum = sum + {24'd0, vfoot[i]};
      sum = ~sum;
      be32(64, sum);
      if (variant == 2) vfoot[64] = vfoot[64] ^ 8'h01;
      for (i = 0; i < 512; i = i + 1) host_img[DATA_BYTES + i] = vfoot[i];
      host_bytes = VHD_BYTES;
    end
  endtask

  // ==== the one image the host serves ====
  // hps_io's side: a read is served with a latency, one slot at a time, over the shared
  // sd_buff bus; a write reads the drive's buffer out at the addresses the host presents.
  reg        a_ack = 0;
  reg        sd_buff_wr = 0;
  reg [12:0] sd_buff_addr = 0;
  reg [15:0] sd_buff_dout = 0;

  reg [31:0] rd_lba [0:1023];
  reg [31:0] wr_lba [0:1023];
  integer    rd_n, wr_n;
  integer    hblk, hi2, hslot_w;
  reg [31:0] h_lba;
  reg [2:0]  h_state = 3'd0;   // 0 idle, 1 read stream, 2 write stream

  function automatic [15:0] host_word(input [31:0] lba, input [7:0] w);
    integer base;
    begin
      base = integer'(lba) * SEC_BYTES + 2 * integer'(w);
      if (base < 0 || base >= host_bytes) host_word = 16'hEEEE;
      else host_word = {host_img[base + 1], host_img[base]};
    end
  endfunction

  always @(negedge clk) begin
    sd_buff_wr <= 1'b0;
    if (h_state == 3'd0) begin
      if (wire_rd) begin
        h_lba = wire_lba;
        hblk  = (integer'(wire_blk) + 1) * 256;
        if (rd_n < 1024) begin rd_lba[rd_n] = wire_lba; rd_n = rd_n + 1; end
        repeat (20) @(negedge clk);
        a_ack <= 1'b1;
        hi2 = 0; h_state = 3'd1;
      end else if (wire_wr) begin
        h_lba = wire_lba;
        if (wr_n < 1024) begin wr_lba[wr_n] = wire_lba; wr_n = wr_n + 1; end
        repeat (20) @(negedge clk);
        a_ack <= 1'b1;
        hi2 = 0; h_state = 3'd2;
      end
    end else if (h_state == 3'd1) begin
      if (hi2 < hblk) begin
        sd_buff_wr   <= 1'b1;
        sd_buff_addr <= hi2[12:0];
        sd_buff_dout <= host_word(h_lba + (hi2 >> 8), hi2[7:0]);
        hi2 = hi2 + 1;
      end else begin
        a_ack <= 1'b0; h_state = 3'd0;
      end
    end else begin
      if (hi2 < 256) begin
        sd_buff_addr <= hi2[12:0];
        @(negedge clk);
        host_img[integer'(h_lba) * SEC_BYTES + 2 * hi2 + 0] = wire_din[7:0];
        host_img[integer'(h_lba) * SEC_BYTES + 2 * hi2 + 1] = wire_din[15:8];
        hi2 = hi2 + 1;
      end else begin
        a_ack <= 1'b0; h_state = 3'd0;
      end
    end
  end

  // ==== DUT ====
  // the real ATA, the detector and the shared engine, plus a detector alone for the
  // mount-race cases the ATA cannot reach
  reg io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0]  io_din = 0;
  wire [7:0] io_dout;
  wire       irq;

  wire ata_block_read, ata_block_write;
  wire [31:0] ata_block_lba;
  wire ata_block_done, ata_block_error;
  wire ata_buf_we;
  wire [7:0]  ata_buf_addr;
  wire [15:0] ata_buf_data;
  wire [7:0]  ata_buf_rd_addr;
  wire [15:0] ata_buf_rd_data;

  wire hdd_mounted, hdd_readonly;
  wire [31:0] hdd_capacity;
  wire hdd_busy;

  wire a_req_read, a_req_write;
  wire [31:0] a_req_lba;
  wire a_req_window;
  wire a_req_done, a_req_error;
  wire a_buf_we;
  wire [7:0]  a_buf_addr;
  wire [15:0] a_buf_data;
  wire [31:0] sd_lba;
  wire [5:0]  sd_blk_cnt;
  wire sd_rd, sd_wr;
  wire [15:0] sd_din;

  // the host model's view of whichever slot requested
  wire        wire_rd  = sd_rd;
  wire        wire_wr  = sd_wr;
  wire [31:0] wire_lba = sd_lba;
  wire [5:0]  wire_blk = sd_blk_cnt;
  wire [15:0] wire_din = sd_din;

  reg img_mounted = 0, img_readonly = 0;
  reg [63:0] img_size = 0;

  pc9821_ata ata (
      .clk(clk), .rst_n(rst_n),
      .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din), .io_dout(io_dout),
      .mounted(hdd_mounted), .readonly(hdd_readonly), .capacity(hdd_capacity),
      .block_read(ata_block_read), .block_write(ata_block_write), .block_lba(ata_block_lba),
      .block_done(ata_block_done), .block_error(ata_block_error),
      .block_buf_we(ata_buf_we), .block_buf_addr(ata_buf_addr),
      .block_buf_data(ata_buf_data),
      .block_rd_addr(ata_buf_rd_addr), .block_rd_data(ata_buf_rd_data),
      .irq(irq),
      /* verilator lint_off PINCONNECTEMPTY */
      .dbg_state(), .dbg_cmd(), .dbg_lba(), .dbg_sec()
      /* verilator lint_on PINCONNECTEMPTY */
  );

  /* verilator lint_off PINCONNECTEMPTY */
  pc9821_hdd_image hdi (
      .clk(clk), .rst_n(rst_n),
      .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
      .mounted(hdd_mounted), .readonly(hdd_readonly), .capacity(hdd_capacity),
      .req_read(ata_block_read), .req_write(ata_block_write), .req_lba(ata_block_lba),
      .req_done(ata_block_done), .req_error(ata_block_error), .busy(hdd_busy),
      .buf_we(ata_buf_we), .buf_addr(ata_buf_addr), .buf_data(ata_buf_data),
      .a_req_read(a_req_read), .a_req_write(a_req_write), .a_req_lba(a_req_lba),
      .a_req_window(a_req_window),
      .a_req_done(a_req_done), .a_req_error(a_req_error),
      .a_buf_we(a_buf_we), .a_buf_addr(a_buf_addr), .a_buf_data(a_buf_data)
  );

  pc9821_block_share share (
      .clk(clk), .rst_n(rst_n),
      .a_img_mounted(img_mounted), .a_img_readonly(img_readonly), .a_img_size(img_size),
      .a_mounted(), .a_readonly(), .a_capacity(),
      .a_req_read(a_req_read), .a_req_write(a_req_write), .a_req_lba(a_req_lba),
      .a_req_window(a_req_window),
      .a_req_done(a_req_done), .a_req_error(a_req_error), .a_busy(),
      .a_buf_we(a_buf_we), .a_buf_addr(a_buf_addr), .a_buf_data(a_buf_data),
      .a_buf_rd_addr(ata_buf_rd_addr), .a_buf_rd_data(ata_buf_rd_data),
      .a_sd_lba(sd_lba), .a_sd_blk_cnt(sd_blk_cnt),
      .a_sd_rd(sd_rd), .a_sd_wr(sd_wr),
      .a_sd_ack(a_ack), .a_sd_buff_din(sd_din),
      .b_img_mounted(1'b0), .b_img_readonly(1'b1), .b_img_size(64'd0),
      .b_req_read(1'b0), .b_req_write(1'b0), .b_req_lba(16'd0), .b_req_slot(1'b0),
      .b_req_done(), .b_req_error(), .b_busy(),
      .b_buf_we(), .b_buf_addr(), .b_buf_data(),
      .b_buf_rd_addr(), .b_buf_rd_data(16'd0),
      .b_sd_lba(), .b_sd_blk_cnt(), .b_sd_rd(), .b_sd_wr(), .b_sd_ack(1'b0), .b_sd_buff_din(),
      .c_img_mounted(1'b0), .c_img_readonly(1'b1), .c_img_size(64'd0),
      .c_sd_lba(), .c_sd_blk_cnt(), .c_sd_rd(), .c_sd_wr(), .c_sd_ack(1'b0), .c_sd_buff_din(),
      .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
      .dbg_hps_cycles()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // ==== the detector alone, for the mount-race cases the ATA cannot reach ====
  // The ATA is held not-ready during a probe, so a guest command cannot be queued in that
  // window through it; this second instance drives the drive-side request port directly
  // against a block-port stub and pins the one-deep hold and the remount-during-probe
  // discard.
  reg        r_img_mounted = 0;
  reg [63:0] r_img_size = 0;
  reg        r_req_read = 0;
  wire       r_req_done, r_req_error;
  wire       r_mounted, r_readonly, r_busy;
  wire [31:0] r_capacity;
  wire       r_a_rd, r_a_wr;
  wire [31:0] r_a_lba;
  wire       r_a_window, r_a_done;
  reg        r_a_err = 0;

  reg [15:0] stub_hdr [0:15];
  reg [15:0] stub_lat [0:15];
  reg        stub_we = 0;
  reg [7:0]  stub_addr = 0;
  reg [15:0] stub_data = 0;
  reg        stub_done = 0;
  integer    stub_state = 0;
  integer    stub_cnt = 0;
  integer    stub_delay = 40;
  reg [31:0] stub_lba_log [0:7];
  reg        stub_win_log [0:7];
  integer    stub_n = 0;
  integer    si;

  pc9821_hdd_image hdi_race (
      .clk(clk), .rst_n(rst_n),
      .img_mounted(r_img_mounted), .img_readonly(1'b0), .img_size(r_img_size),
      .mounted(r_mounted), .readonly(r_readonly), .capacity(r_capacity),
      .req_read(r_req_read), .req_write(1'b0), .req_lba(32'd9),
      .req_done(r_req_done), .req_error(r_req_error), .busy(r_busy),
      .buf_we(), .buf_addr(), .buf_data(),
      .a_req_read(r_a_rd), .a_req_write(r_a_wr), .a_req_lba(r_a_lba),
      .a_req_window(r_a_window),
      .a_req_done(stub_done), .a_req_error(r_a_err),
      .a_buf_we(stub_we), .a_buf_addr(stub_addr), .a_buf_data(stub_data)
  );

  always @(negedge clk) begin
    if (stub_state == 0) begin
      stub_we <= 1'b0;
      stub_done <= 1'b0;
      if (r_a_rd) begin
        if (stub_n < 8) begin
          stub_lba_log[stub_n] = r_a_lba;
          stub_win_log[stub_n] = r_a_window;
          stub_n = stub_n + 1;
        end
        for (si = 0; si < 16; si = si + 1) stub_lat[si] = stub_hdr[si];
        stub_cnt   = 0;
        stub_delay = 40;
        stub_state = 1;
      end
    end else if (stub_state == 1) begin
      if (stub_delay != 0) stub_delay = stub_delay - 1;
      else if (stub_cnt < 256) begin
        stub_we   <= 1'b1;
        stub_addr <= stub_cnt[7:0];
        stub_data <= (stub_cnt < 16) ? stub_lat[stub_cnt] : 16'h1234;
        stub_cnt  = stub_cnt + 1;
      end else begin
        stub_we    <= 1'b0;
        stub_done  <= 1'b1;
        stub_state = 2;
      end
    end else begin
      stub_done  <= 1'b0;
      stub_state = 0;
    end
  end

  // r_* request ports for the race DUT: one-cycle read pulses, ATA-style.
  task automatic race_request;
    begin
      @(negedge clk);
      r_req_read = 1'b1;
      @(negedge clk);
      r_req_read = 1'b0;
    end
  endtask

  // ==== CHECKS ====
  // guest task-file helpers (the Linux/98 driver's sequence)
  task automatic fail(input [8*160-1:0] m);
    begin
      $display("  FAIL: %0s @ %0t", m, $time);
      errors = errors + 1;
    end
  endtask

  task automatic tf_read(input [15:0] addr, output [7:0] data);
    begin
      io_addr = addr; io_rd = 1;
      #1 data = io_dout;
      @(negedge clk);
      io_rd = 0;
      repeat (3) @(negedge clk);
    end
  endtask

  task automatic tf_write(input [15:0] addr, input [7:0] data);
    begin
      io_addr = addr; io_din = data; io_wr = 1;
      @(negedge clk);
      io_wr = 0;
      repeat (3) @(negedge clk);
    end
  endtask

  task automatic wait_not_busy(output [7:0] st);
    integer n;
    begin
      n = 0; st = 8'h80;
      while (st[7] && n < 200000) begin tf_read(16'h074C, st); n = n + 1; end
      if (st[7]) fail("BSY never cleared");
    end
  endtask

  task automatic read_word(output [15:0] w);
    reg [7:0] lo, hi8;
    begin
      tf_read(16'h0640, lo);
      tf_read(16'h0641, hi8);
      w = {hi8, lo};
    end
  endtask

  task automatic write_word(input [15:0] w);
    begin
      tf_write(16'h0640, w[7:0]);
      tf_write(16'h0641, w[15:8]);
    end
  endtask

  task automatic select_drive;
    begin
      tf_write(16'h0432, 8'h00);       // bank 0, the disk's fixed position
      tf_write(16'h064C, 8'hE0);       // LBA mode, master
    end
  endtask

  reg [15:0] id_w [0:255];
  reg [15:0] id_hdi [0:255];
  reg [15:0] id_raw [0:255];
  reg [15:0] id_vhd [0:255];
  reg [7:0]  vfoot_copy [0:511];

  task automatic identify;
    reg [7:0] st;
    reg [15:0] w;
    integer i;
    begin
      select_drive;
      tf_write(16'h064E, 8'hEC);
      wait_not_busy(st);
      if (!st[3]) fail("IDENTIFY raised no DRQ");
      for (i = 0; i < 256; i = i + 1) begin read_word(w); id_w[i] = w; end
      tf_read(16'h064E, st);
    end
  endtask

  // A READ SECTORS of `count` sectors from guest LBA `lba`, checked against the payload.
  task automatic read_payload(input [31:0] lba, input [7:0] count, input [8*48-1:0] what);
    reg [7:0] st;
    reg [15:0] w;
    integer s, i, bad;
    begin
      bad = 0;
      select_drive;
      tf_write(16'h0644, count);
      tf_write(16'h0646, lba[7:0]);
      tf_write(16'h0648, lba[15:8]);
      tf_write(16'h064A, lba[23:16]);
      tf_write(16'h064E, 8'h20);
      for (s = 0; s < count; s = s + 1) begin
        wait_not_busy(st);
        if (!st[3] || st[0]) begin fail({what, ": no DRQ / ERR on a sector"}); s = count; end
        else begin
          for (i = 0; i < 256; i = i + 1) begin
            read_word(w);
            if (w !== pword(integer'(lba) + s, i)) begin
              if (bad == 0)
                $display("    %0s: lba %0d word %0d = %04x, payload holds %04x", what,
                         lba + s, i, w, pword(integer'(lba) + s, i));
              bad = bad + 1;
            end
          end
        end
      end
      tf_read(16'h064E, st);
      if (bad != 0) fail({what, ": sector data is not the payload"});
    end
  endtask

  // A READ SECTORS at an LBA the drive must refuse: STATUS.ERR, no DRQ, no data.
  task automatic read_expect_abort(input [31:0] lba, input [8*48-1:0] what);
    reg [7:0] st;
    begin
      select_drive;
      tf_write(16'h0644, 8'd1);
      tf_write(16'h0646, lba[7:0]);
      tf_write(16'h0648, lba[15:8]);
      tf_write(16'h064A, lba[23:16]);
      tf_write(16'h064E, 8'h20);
      wait_not_busy(st);
      if (!st[0] || st[3]) fail({what, ": an out-of-range read was not aborted"});
      tf_read(16'h064E, st);
    end
  endtask

  // A one-sector WRITE SECTORS of a pattern that names the guest LBA.
  function automatic [15:0] wpat(input [31:0] lba, input integer w);
    begin
      wpat = {lba[7:0] ^ 8'hA5, 8'(w)};
    end
  endfunction

  task automatic write_sector(input [31:0] lba, output [7:0] st);
    integer i;
    begin
      select_drive;
      tf_write(16'h0644, 8'd1);
      tf_write(16'h0646, lba[7:0]);
      tf_write(16'h0648, lba[15:8]);
      tf_write(16'h064A, lba[23:16]);
      tf_write(16'h064E, 8'h30);
      wait_not_busy(st);
      if (!st[3] || st[0]) fail("WRITE SECTORS did not arm its data phase");
      for (i = 0; i < 256; i = i + 1) write_word(wpat(lba, i));
      // The block write is still streaming to the host: BSY clears only when the engine has
      // taken the sector and acknowledged it.
      wait_not_busy(st);
      tf_read(16'h064E, st);
    end
  endtask

  task automatic mount(input [63:0] sz);
    begin
      @(negedge clk);
      img_size = sz;
      img_mounted = 1'b1;
      @(negedge clk);
      img_mounted = 1'b0;
    end
  endtask

  task automatic wait_mounted;
    integer n;
    begin
      n = 0;
      while (!hdd_mounted && n < 200000) begin @(negedge clk); n = n + 1; end
      if (!hdd_mounted) fail("the drive never reported ready after a mount");
    end
  endtask

  reg [7:0] st0;
  integer   i, n;
  reg [7:0] hdr_copy [0:HDR_BYTES-1];

  initial begin
    #400_000_000;
    $fatal(1, "TB_PC9821_HDI_IMG: watchdog timeout (no verdict reached)");
  end

  initial begin
    errors = 0; rd_n = 0; wr_n = 0;
    build_image(0);
    host_bytes = HDI_BYTES;
    repeat (6) @(negedge clk);
    rst_n = 1;
    repeat (50) @(negedge clk);

    // ================================================================ A: HDI mounted
    mount(64'(HDI_BYTES));
    wait_mounted;
    repeat (200) @(negedge clk);         // let the ATA's geometry divider fold capacity in
    if (hdd_capacity !== CAP_DATA)
      fail("A: capacity is not DataSize/512 (the header's sectors were not subtracted)");

    identify;
    for (i = 0; i < 256; i = i + 1) id_hdi[i] = id_w[i];
    if ({id_w[61], id_w[60]} !== CAP_DATA) fail("A: IDENTIFY words 60/61 are not DataSize/512");

    read_payload(32'd0,  8'd1, "A: HDI read of guest LBA 0");
    read_payload(32'd3,  8'd2, "A: HDI read of guest LBA 3..4");
    read_payload(32'd67, 8'd1, "A: HDI read of guest LBA 67 (the last payload sector)");

    // The header sector (file LBA 0..7) must have been read exactly once, by the probe, and
    // never as guest data.
    n = 0;
    for (i = 0; i < rd_n; i = i + 1) if (rd_lba[i] < 8) n = n + 1;
    if (n != 1) fail("A: the header's sectors were read as data (the probe alone may read LBA 0)");
    // Every guest read is offset: no read below the header after the probe.
    for (i = 1; i < rd_n; i = i + 1)
      if (rd_lba[i] < 8) fail("A: a guest read named a header sector");

    // Write guest LBA 5: it must land at file LBA 5 + 8 and leave the header intact.
    for (i = 0; i < HDR_BYTES; i = i + 1) hdr_copy[i] = host_img[i];
    write_sector(32'd5, st0);
    if (st0 !== 8'h50) fail("A: WRITE SECTORS did not complete READY|DSC");
    if (wr_n != 1) fail("A: the write did not reach the host once");
    if (wr_lba[0] !== 32'd13) fail("A: a guest write of LBA 5 did not land at file LBA 13");
    for (i = 0; i < 256; i = i + 1) begin
      if (host_img[13 * SEC_BYTES + 2 * i]     !== wpat(32'd5, i)[7:0])  fail("A: write byte mismatch");
      if (host_img[13 * SEC_BYTES + 2 * i + 1] !== wpat(32'd5, i)[15:8]) fail("A: write byte mismatch");
    end
    for (i = 0; i < HDR_BYTES; i = i + 1)
      if (host_img[i] !== hdr_copy[i]) fail("A: the write touched the HDI header");

    // A remount goes NOT READY while its header sector is read: a guest probing in this
    // window sees STATUS 0x00, never the previous image's stale ready.
    mount(64'(HDI_BYTES));
    tf_read(16'h064E, st0);
    // While the probe runs the drive is not present, so the task file answers 0xFF (the
    // ATA's own "no drive on this channel" value, pc9821_ata.sv:555) rather than a ready
    // status for an image whose header has not been checked yet.
    if (st0 !== 8'hFF) fail("A: STATUS was not the no-drive 0xFF while a remount's probe ran");
    wait_mounted;
    repeat (200) @(negedge clk);
    if (hdd_capacity !== CAP_DATA) fail("A: the remount did not report DataSize/512");

    // ================================================================ B: eject
    mount(64'd0);
    repeat (20) @(negedge clk);
    if (hdd_mounted) fail("B: the drive still reports ready after an eject");
    if (hdd_capacity !== 32'd0) fail("B: capacity did not clear on eject");

    // ================================================================ C: the same payload raw
    build_raw;
    host_bytes = DATA_BYTES;
    rd_n = 0; wr_n = 0;
    mount(64'(DATA_BYTES));
    wait_mounted;
    repeat (200) @(negedge clk);
    if (hdd_capacity !== CAP_DATA) fail("C: the raw image's capacity changed");
    identify;
    for (i = 0; i < 256; i = i + 1) id_raw[i] = id_w[i];
    for (i = 0; i < 256; i = i + 1)
      if (id_raw[i] !== id_hdi[i])
        fail("C: the raw image's IDENTIFY page differs from the HDI mount's");
    read_payload(32'd0,  8'd1, "C: raw read of guest LBA 0");
    read_payload(32'd3,  8'd2, "C: raw read of guest LBA 3..4");
    read_payload(32'd67, 8'd1, "C: raw read of guest LBA 67");
    write_sector(32'd5, st0);
    if (st0 !== 8'h50) fail("C: raw WRITE SECTORS did not complete READY|DSC");
    if (wr_n != 1) fail("C: the raw write did not reach the host once");
    if (wr_lba[0] !== 32'd5) fail("C: a raw guest write of LBA 5 landed at the wrong file LBA");

    // ================================================================ D: fixed VHD
    // The same 68 payload sectors with a 512-byte big-endian footer appended. Data is at
    // file offset 0, so a write lands at the guest LBA; the footer's sector is beyond the
    // virtual disk and must never be a guest LBA.
    build_vhd(0);
    rd_n = 0; wr_n = 0;
    mount(64'(VHD_BYTES));
    wait_mounted;
    repeat (200) @(negedge clk);
    if (hdd_capacity !== CAP_DATA) begin
      $display("    VHD dbg: cap=%0d vhd_ok=%b kind=%b sum=%08x csum=%08x cur_lo=%011x cur_hi_z=%b type_ok=%b%b dof_w=%b cookie=%b tailok=%b",
               hdd_capacity, hdi.vhd_ok, hdi.probe_kind, hdi.vhd_sum, hdi.vhd_csum,
               hdi.v_cur_lo, hdi.vhd_cur_hi_z, hdi.v_type_hi_z, hdi.v_type_lo_2, hdi.v_dof_w,
               hdi.vhd_cookie_ok, hdi.tail_ok);
      fail("D: the fixed VHD's capacity is not current size/512");
    end
    identify;
    for (i = 0; i < 256; i = i + 1) id_vhd[i] = id_w[i];
    for (i = 0; i < 256; i = i + 1)
      if (id_vhd[i] !== id_hdi[i]) fail("D: the VHD mount's IDENTIFY page differs from the raw/HDI one");
    // The two probes are the whole file's first and last sectors; no guest access is one.
    if (rd_n < 2) fail("D: the front and tail probes did not both run");
    if (rd_lba[0] !== 32'd0) fail("D: the VHD's front probe was not LBA 0");
    if (rd_lba[1] !== 32'd68) fail("D: the VHD's tail probe was not the file's last LBA");
    read_payload(32'd0,  8'd1, "D: VHD read of guest LBA 0");
    read_payload(32'd3,  8'd2, "D: VHD read of guest LBA 3..4");
    read_payload(32'd67, 8'd1, "D: VHD read of guest LBA 67");
    // LBA 68 is the footer's sector: the drive must refuse it (capacity 68), so the footer is
    // never data.
    read_expect_abort(32'd68, "D: VHD footer as guest data");
    // A write at guest LBA 5 lands at FILE LBA 5 (offset 0) and leaves the footer alone.
    for (i = 0; i < 512; i = i + 1) vfoot_copy[i] = host_img[DATA_BYTES + i];
    write_sector(32'd5, st0);
    if (st0 !== 8'h50) fail("D: VHD WRITE SECTORS did not complete READY|DSC");
    if (wr_n != 1) fail("D: the VHD write did not reach the host once");
    if (wr_lba[0] !== 32'd5) fail("D: a VHD guest write of LBA 5 did not land at file LBA 5");
    for (i = 0; i < 256; i = i + 1) begin
      if (host_img[5 * SEC_BYTES + 2 * i]     !== wpat(32'd5, i)[7:0])  fail("D: VHD write byte mismatch");
      if (host_img[5 * SEC_BYTES + 2 * i + 1] !== wpat(32'd5, i)[15:8]) fail("D: VHD write byte mismatch");
    end
    for (i = 0; i < 512; i = i + 1)
      if (host_img[DATA_BYTES + i] !== vfoot_copy[i]) fail("D: the VHD write touched the footer");

    // ================================================================ E: corrupt VHD footers are raw
    for (i = 1; i <= 5; i = i + 1) begin
      build_vhd(i);
      rd_n = 0; wr_n = 0;
      mount(64'(VHD_BYTES));
      wait_mounted;
      repeat (100) @(negedge clk);
      if (hdd_capacity !== CAP_RAW_VHD)
        fail("E: a corrupt VHD footer was treated as fixed (capacity is not the file's own)");
      read_payload(32'd0, 8'd1, "E: a corrupt VHD did not fall back to the raw file");
      mount(64'd0);
      repeat (20) @(negedge clk);
    end

    // ================================================================ F: corrupt headers are raw
    // Only the headers NP2kai's sxsihdd.c would refuse (a zero or too large geometry field, a
    // sector size this ATA cannot serve), plus the two the content detection needs in place of
    // NP2kai's extension test (reserved == 0, a whole-sector HeaderSize).
    for (i = 1; i <= 10; i = i + 1) if (i != 2 && i != 3 && i != 7 && i != 8) begin
      build_image(i);
      host_bytes = HDI_BYTES;
      rd_n = 0; wr_n = 0;
      mount(64'(HDI_BYTES));
      wait_mounted;
      repeat (50) @(negedge clk);
      if (hdd_capacity !== CAP_RAW_HDI)
        fail("F: a corrupt header was treated as HDI (capacity is not the file's own)");
      // Guest LBA 0 is the file's first sector - header bytes and all - so no offset was
      // applied. Word 0 of the file is reserved's low half; word 1 is reserved's high half.
      read_payload_file0(i);
      mount(64'd0);
      repeat (20) @(negedge clk);
    end

    // ================================================================ H: NP2kai's HDIs
    // Headers NP2kai mounts as HDI although the file is not exactly header + DataSize +
    // geometry: a DataSize that disagrees, a geometry past the file or short of DataSize, and a
    // file with trailing padding. Each mounts with the header's offset and NP2kai's capacity.
    for (i = 2; i <= 8; i = i + 1) if (i == 2 || i == 3 || i == 7 || i == 8) begin
      build_image(i);
      host_bytes = HDI_BYTES + ((i == 7) ? PAD_BYTES : 0);
      rd_n = 0; wr_n = 0;
      mount(64'(host_bytes));
      wait_mounted;
      repeat (200) @(negedge clk);
      if (hdd_capacity !== np2_hdi_cap(host_bytes)) begin
        $display("    H variant %0d: capacity %0d, want %0d", i, hdd_capacity, np2_hdi_cap(host_bytes));
        fail("H: an HDI NP2kai mounts did not mount as HDI with NP2kai's capacity");
      end
      read_payload(32'd0, 8'd1, "H: guest LBA 0 of an HDI NP2kai mounts");
      read_payload(np2_hdi_cap(host_bytes) - 1, 8'd1, "H: the last guest LBA of an HDI NP2kai mounts");
      mount(64'd0);
      repeat (20) @(negedge clk);
    end

    // ================================================================ G: the race DUT
    // Image 1 (68 payload sectors), then image 2 (40) mounted while the first probe is still
    // in flight; a guest request is pulsed during the probe.
    begin : race
      integer w1;
      // image 1's header words: HeaderSize 4096, DataSize 34816, 512, 17, 2, 2.
      w1 = 0;
      stub_set(32'd4096, DATA_BYTES, 32'd512, 32'd17, 32'd2, 32'd2);
      r_img_size = 64'(HDI_BYTES);
      @(negedge clk); r_img_mounted = 1'b1; @(negedge clk); r_img_mounted = 1'b0;
      race_request;                       // queued while the probe is in flight
      if (r_mounted) fail("G: the drive reported ready during the probe");
      // image 2: 5*2*4*512 = 20480 bytes, 40 sectors, also a 4096-byte header.
      stub_set(32'd4096, 32'd20480, 32'd512, 32'd5, 32'd2, 32'd4);
      r_img_size = 64'(4096 + 20480);
      @(negedge clk); r_img_mounted = 1'b1; @(negedge clk); r_img_mounted = 1'b0;
      w1 = 0;
      while (!r_req_done && w1 < 100000) begin @(negedge clk); w1 = w1 + 1; end
      if (!r_req_done) fail("G: the queued guest request was never completed");
      if (r_req_error) fail("G: the queued guest request completed with an error");
      if (!r_mounted) fail("G: the drive was not ready after the second probe");
      if (r_capacity !== 32'd40) fail("G: the remount-during-probe kept the first image's capacity");
      // The stub saw: probe image 1 (lba 0, window LOW), probe image 2 (lba 0, window LOW),
      // the guest request (lba 9 + 8, window HIGH).
      if (stub_n != 3) fail("G: the stub did not see exactly two probes and one guest request");
      if (stub_lba_log[0] !== 32'd0 || stub_win_log[0] !== 1'b0) fail("G: first probe was not LBA 0 with the window off");
      if (stub_lba_log[1] !== 32'd0 || stub_win_log[1] !== 1'b0) fail("G: the re-issued probe was not LBA 0 with the window off");
      if (stub_lba_log[2] !== 32'd17 || stub_win_log[2] !== 1'b1) fail("G: the guest request was not LBA 9 + the header offset");
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_HDI_IMG: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_HDI_IMG: FAIL (%0d errors)", errors);
  end

  // The corrupt-header read: guest LBA 0 is the file's own first sector.
  task automatic read_payload_file0(input integer variant);
    reg [7:0] st;
    reg [15:0] w;
    integer i, bad;
    begin
      bad = 0;
      select_drive;
      tf_write(16'h0644, 8'd1);
      tf_write(16'h0646, 8'd0);
      tf_write(16'h0648, 8'd0);
      tf_write(16'h064A, 8'd0);
      tf_write(16'h064E, 8'h20);
      wait_not_busy(st);
      if (!st[3] || st[0]) fail("F: the raw fallback did not serve LBA 0");
      for (i = 0; i < 256; i = i + 1) begin
        read_word(w);
        if (w !== {host_img[2 * i + 1], host_img[2 * i]}) begin
          bad = bad + 1;
          if (bad == 1)
            $display("    F variant %0d: LBA 0 word %0d = %04x, the file holds %04x",
                     variant, i, w, {host_img[2 * i + 1], host_img[2 * i]});
        end
      end
      if (bad != 0) fail("F: the raw fallback served bytes other than the file's own LBA 0");
      tf_read(16'h064E, st);
    end
  endtask

  // Pack a header into the race stub's 16 words (and the same DWORDs the image builder uses).
  task automatic stub_set(input [31:0] hsize, input [31:0] dsize, input [31:0] bps,
                          input [31:0] spt, input [31:0] heads, input [31:0] cyls);
    begin
      stub_hdr[0]  = 16'd0;               stub_hdr[1]  = 16'd0;              // reserved
      stub_hdr[2]  = 16'd32;              stub_hdr[3]  = 16'd0;              // type
      stub_hdr[4]  = hsize[15:0];         stub_hdr[5]  = hsize[31:16];
      stub_hdr[6]  = dsize[15:0];         stub_hdr[7]  = dsize[31:16];
      stub_hdr[8]  = bps[15:0];           stub_hdr[9]  = bps[31:16];
      stub_hdr[10] = spt[15:0];           stub_hdr[11] = spt[31:16];
      stub_hdr[12] = heads[15:0];         stub_hdr[13] = heads[31:16];
      stub_hdr[14] = cyls[15:0];          stub_hdr[15] = cyls[31:16];
    end
  endtask

endmodule
