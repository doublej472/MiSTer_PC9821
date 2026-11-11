// HDI (Anex86 / FDI) hard-disk image detection and sector offset.
//
// THE FORMAT. An HDI is a 32-byte little-endian header followed by an optional comment
// space, then the raw C/H/S data:
//
//   0x00 DWORD reserved, must be 0
//   0x04 DWORD FDD type / capacity in MB (no magic value to test)
//   0x08 DWORD HeaderSize (default 4096; 32 is the smallest the format allows)
//   0x0C DWORD DataSize (DataSize + HeaderSize == file size; NP2kai never reads it)
//   0x10 DWORD bytes per sector
//   0x14 DWORD sectors per track
//   0x18 DWORD heads
//   0x1C DWORD cylinders
//
// (https://www.pc98.org/project/doc/hdi.html, "HDI / FDI File Format"; NP2kai
// fdd/sxsihdd.h's `HDIHDR` has the same field order, `UINT8 headersize[4]; UINT8 hddsize[4];`
// and its reader fdd/sxsihdd.c offsets every access by `headersize`
// (`pos = pos * sxsi->size + sxsi->headersize;`).)
//
// WHY CONTENT AND NOT THE FILE NAME. hps_io hands the core a size and a pulse, never a name,
// so a `.hdi` can only be recognised from its bytes. NP2kai decides HDI by the extension and
// then checks only the geometry (fdd/sxsihdd.c: the `.hdi` arm reads headersize, surfaces,
// cylinders, sectors and sectorsize, and the format check after it rejects a zero or too large
// field and a sector size that is not a power of two). This module accepts every header NP2kai
// accepts for a 512-byte-sector IDE disk, plus what content detection needs in place of the
// extension: the reserved first DWORD must be 0 (the first DWORD of a raw PC-98 disk is its
// IPL and is not zero) and HeaderSize must be a whole number of sectors in [512, 1 MiB].
//
// WHERE IT SITS. This module is the seam between pc9821_ata and pc9821_block_share's A
// port: the ATA still sees one drive with one capacity, and every guest LBA is translated to
// `lba + HeaderSize/512` for reads AND writes. The header's own sectors are never named by
// a guest request, so no write can touch them. The engine's own range check still uses the
// file's raw sector count, and this module's capacity is the payload's, so an LBA the guest
// can name is always inside the file.
//
// THE MOUNT PROBE. At each mount the detector reads sector 0 through the same block port
// (one 512-byte read, LBA 0) with the read-ahead window tag LOW, so the probe neither fills
// nor invalidates the engine's window and a raw image's first guest access keeps the exact
// miss it had before. If that sector is not an HDI, a second probe reads the image's LAST
// sector for the fixed-VHD footer, again with the window tag LOW. Until the probes land,
// `mounted` is 0; the ATA's task file then answers the no-drive value 0xFF (its own "no drive
// on this channel" read) instead of a ready status for an image whose format has not been
// checked. A mount that lands during a probe invalidates that probe (its sector belongs to the
// replaced image) and restarts from the front; an eject abandons it. A guest request arriving
// in the probe window is held one deep and served after it with the new offset; the ATA is
// already holding BSY for the command. The parsed offset and capacity survive a platform
// reset, like the other medium latches (the host never re-sends `img_mounted` after an OSD
// reset); only an eject or a replacement mount clears them.
//
// A HEADER THAT DOES NOT VALIDATE IS A RAW IMAGE. reserved != 0, HeaderSize outside
// [32, 1 MiB] or not a multiple of the sector size, bytes/sector != 512 (the ATA's own
// sector), or a geometry field that is 0 or past NP2kai's bounds (fdd/sxsihdd.c:
// `surfaces >= 256`, `cylinders >= 65536`, `sectors >= 256` are rejected) all fall back to
// offset 0 and the file's own size, which is exactly what this core did before HDI existed.
// A 32-byte, unpadded header is one of those fallbacks: the block port addresses whole
// 512-byte sectors, so a data segment starting inside sector 0 has no LBA. DataSize is not
// tested, and the file need not be exactly header + geometry: NP2kai reads neither
// (`totals = (FILEPOS)cylinders * sectors * surfaces;`), so trailing padding or a DataSize
// that disagrees still mounts as HDI.
//
// THE CAPACITY is NP2kai's totals, cylinders x heads x sectors, clamped to the sectors the
// file holds after the header: an LBA the guest can name is always inside the file. NP2kai
// reports the whole geometry of a truncated file and fails the reads past its end; here such a
// disk reports the shorter size (a recorded divergence, for a damaged image only).
//
// FIXED VHD (Virtual PC). A fixed VHD has its guest data at file offset 0 and a 512-byte
// footer at the END of the file, all fields big-endian (Microsoft Virtual Hard Disk Image
// Format Specification; NP2kai fdd/hdd_vhd.h "a minimal support for VirtualPC VHD images
// (fixed disk image only, for now...)"). If the front header is not an HDI, a second probe
// reads the image's LAST sector and accepts it only when the footer says fixed:
// cookie "conectix", data offset all-ones (`0xFFFFFFFFFFFFFFFF`, a fixed disk has no
// dynamic header to point at), disk type 2, `current size` a non-zero multiple of 512 with
// `current size + 512 <= file size`, the high bits that would not fit the 32-bit sector
// count clear, and the footer checksum (one's complement of the sum of all 512 bytes with
// the checksum field zeroed). Then offset is 0 (so a write lands at the guest LBA) and the
// guest capacity is `current size / 512`, which keeps the footer's own sector - the last
// sector of the file - outside every LBA the guest can name. A dynamic or differencing VHD
// (disk type 3 or 4; the "cxsparse" dynamic header at offset 512) is NOT supported and
// falls back to raw, rather than being mapped as if its footer were data. The two formats
// are mutually exclusive: an HDI is recognised by its front header and a VHD by its tail,
// and a valid HDI short-circuits the tail probe.
//
// THE OFFSET SURVIVES A PLATFORM RESET, like every other medium latch in this core
// (pc9821_block_io's header): the host keeps the image mounted across an OSD reset and never
// re-sends img_mounted, so clearing the parsed offset there would turn the disk back into a
// raw image with a 4096-byte header in front of the guest's partition table. Only an eject
// (img_mounted with a sub-sector size) or a replacement mount clears it.
//
// TWO DRIVES, ONE DETECTOR. The second hard disk (hps_io slot 3, bank 1's master when the OSD
// puts a disk there) is served by this same module: each drive keeps its own image record (size,
// read-only flag, state, offset, capacity, a pending probe and its kind), and the one probe engine
// and its header/footer captures are lent to one drive at a time. Mounts are rare and hps_io
// delivers them one slot at a time; a mount that arrives while the other drive's probe is in
// flight is held as that drive's pending probe and runs next. A guest request carries the drive
// it is for (`req_unit`, pc9821_ata's `block_unit`), is offset by THAT drive's header and goes to
// the engine tagged with it (`a_req_unit`). Drive 0's behaviour, its cycles included, is the
// one-drive module's whenever slot 3 holds no image.

`default_nettype none

module pc9821_hdd_image (
    input wire clk,
    input wire rst_n,

    // ---------------------------------------------------------------- the host's image event
    // hps_io slot 0's pulse and registers, the same ones pc9821_block_share receives.
    input  wire        img_mounted,
    // hps_io slot 3's pulse (the second hard disk); img_readonly/img_size are hps_io's shared
    // registers, valid with whichever slot's pulse is high.
    input  wire        img_mounted1,
    input  wire        img_readonly,
    input  wire [63:0] img_size,

    // ---------------------------------------------------------------- the drive's side
    // pc9821_ata's block contract: one-cycle req_read/req_write pulses in, one req_done
    // pulse per request with req_error beside it (pc9821_ata.sv clears block_read/
    // block_write at the top of its clocked block).
    output wire        mounted,
    output wire        readonly,
    output wire [31:0] capacity,
    output wire        mounted1,
    output wire        readonly1,
    output wire [31:0] capacity1,
    input  wire        req_read,
    input  wire        req_write,
    input  wire [31:0] req_lba,
    input  wire        req_unit,     // which drive the request is for (sampled with the pulse)
    output reg         req_done,
    output reg         req_error,
    output wire        busy,
    output wire        buf_we,
    output wire [ 7:0] buf_addr,
    output wire [15:0] buf_data,

    // ---------------------------------------------------------------- the shared engine's A port
    output wire        a_req_read,
    output wire        a_req_write,
    output wire [31:0] a_req_lba,
    // LOW for the mount probe and HIGH for every guest request: pc9821_block_io's read-ahead
    // window belongs to the disk's image, and the probe must not put its sector 0 in it (a raw
    // image then keeps the exact first-access miss it had before HDI support existed).
    output wire        a_req_window,
    // Which drive's image the engine request is for: 0 = slot 0, 1 = slot 3.
    output wire        a_req_unit,
    input  wire        a_req_done,
    input  wire        a_req_error,
    input  wire        a_buf_we,
    input  wire [ 7:0] a_buf_addr,
    input  wire [15:0] a_buf_data
);

  localparam [1:0] H_IDLE  = 2'd0,   // no image, or the image is smaller than one sector
                   H_PROBE = 2'd1,   // mounted, header sector not read/validated yet
                   H_READY = 2'd2;   // mount complete: offset and capacity are latched

  // Per drive (index 0 = slot 0, 1 = slot 3).
  reg [1:0]  state [0:1];
  // The image size, kept as what every test below reads of it: bits [40:0] and whether any of
  // [63:41] is set (a size that does not fit the 41-bit byte range a 32-bit sector count names).
  reg [40:0] size_lo_r [0:1];
  reg  [1:0] size_hi_r;
  // The header's sectors, 0..2048 (HeaderSize is at most 1 MiB and a multiple of 512).
  reg [11:0] hdr_off [0:1];
  // One deep each way: the probe the detector owes the engine (per drive), and the guest
  // request the engine owes a completion. A probe and a request are never in flight together.
  reg  [1:0] probe_pending;
  reg        probe_busy;
  reg        probe_unit;     // the drive the probe in flight belongs to
  // 0 = the front probe (HDI header at LBA 0), 1 = the tail probe (fixed-VHD footer at the
  // image's last sector). A mount restarts at the front.
  reg  [1:0] probe_kind;
  reg        ata_pend;
  reg        ata_pend_write;
  reg [31:0] ata_pend_lba;
  reg        ata_pend_unit;
  reg        ata_inflight;
  reg        out_unit;
  reg        out_window;
  reg        out_read;
  reg        out_write;
  reg [31:0] out_lba;
  // THE HEADER AND FOOTER FIELDS, CAPTURED AS THE TESTS READ THEM. Each probe word is latched
  // when its index arrives (any order, a word written twice keeps its last value), but only the
  // part a test below reads is kept: a word compared against a constant is the one-bit result of
  // that compare, and a field whose high bits a bound test needs to be zero keeps its low bits
  // plus that zero flag. The verdicts are the same functions of the same latched words.
  // HDI (front probe, words 0..15; words 2/3, the FDD type, and 6/7, DataSize, are never read):
  reg        h_res0_z, h_res1_z;      // words 0, 1 == 0 (reserved)
  reg [20:0] h_hsize;                 // HeaderSize[20:0] (words 4, 5[4:0])
  reg        h_hsize_hi_z;            // HeaderSize[31:21] == 0
  reg        h_bps_lo_512, h_bps_hi_z;// word 8 == 512, word 9 == 0 (bytes/sector == 512)
  reg [7:0]  h_spt;                   // sectors/track[7:0] (word 10)
  reg        h_spt_hi_z;              // sectors/track[31:8] == 0 (word 10[15:8], word 11)
  reg        h_spt_w11_z;
  reg [7:0]  h_heads;                 // heads[7:0] (word 12)
  reg        h_heads_hi_z;            // heads[31:8] == 0 (word 12[15:8], word 13)
  reg        h_heads_w13_z;
  reg [15:0] h_cyls;                  // cylinders[15:0] (word 14)
  reg        h_cyls_hi_z;             // cylinders[31:16] == 0 (word 15)
  // Fixed-VHD footer (tail probe, words 0..33, big-endian fields):
  reg  [3:0] v_cookie_w;              // words 0..3 == "conectix" in memory order
  reg  [3:0] v_dof_w;                 // words 8..11 == 0xFFFF (data offset all-ones)
  reg        v_cur_w24_z;             // current size[63:48] == 0 (word 24)
  reg  [6:0] v_cur_w25_hi;            // current size[47:41] (word 25, byte-swapped, top 7 bits)
  reg [40:0] v_cur_lo;                // current size[40:0] (words 25..27)
  reg        v_type_hi_z, v_type_lo_2;// disk type: word 30 == 0, word 31 == 2 (byte-swapped)
  reg [15:0] v_csum_w32, v_csum_w33;  // the checksum field (words 32, 33)
  // The running byte sum of the whole 512-byte footer with the checksum field excluded.
  reg [31:0] vhd_sum;

  // readonly's power-up 1 sits on an internal register: Quartus ignores a power-up value on an
  // output port (docs/policies.md, the power-up rule).
  /* verilator lint_off PROCASSINIT */  // the power-up value, kept by Quartus on an internal register
  reg [1:0] readonly_r = 2'b11;
  /* verilator lint_on PROCASSINIT */
  reg [1:0]  mounted_r;
  reg [31:0] capacity_r [0:1];
  assign readonly  = readonly_r[0];
  assign readonly1 = readonly_r[1];
  assign mounted   = mounted_r[0];
  assign mounted1  = mounted_r[1];
  assign capacity  = capacity_r[0];
  assign capacity1 = capacity_r[1];
  initial begin
    state[0]         = H_IDLE;
    state[1]         = H_IDLE;
    size_lo_r[0]     = 41'd0;
    size_lo_r[1]     = 41'd0;
    size_hi_r        = 2'b00;
    hdr_off[0]       = 12'd0;
    hdr_off[1]       = 12'd0;
    probe_pending    = 2'b00;
    probe_busy       = 1'b0;
    probe_unit       = 1'b0;
    probe_kind       = 2'b00;
    ata_pend         = 1'b0;
    ata_pend_write   = 1'b0;
    ata_pend_lba     = 32'd0;
    ata_pend_unit    = 1'b0;
    ata_inflight     = 1'b0;
    out_unit         = 1'b0;
    out_window       = 1'b1;
    out_read         = 1'b0;
    out_write        = 1'b0;
    out_lba          = 32'd0;
    mounted_r        = 2'b00;
    capacity_r[0]    = 32'd0;
    capacity_r[1]    = 32'd0;
    req_done         = 1'b0;
    req_error        = 1'b0;
    vhd_sum          = 32'd0;
    // The power-up value of every capture is the one it has for all-zero words.
    h_res0_z = 1'b1;  h_res1_z = 1'b1;  h_hsize = 21'd0;  h_hsize_hi_z = 1'b1;
    h_bps_lo_512 = 1'b0; h_bps_hi_z = 1'b1;
    h_spt = 8'd0;     h_spt_hi_z = 1'b1;   h_spt_w11_z = 1'b1;
    h_heads = 8'd0;   h_heads_hi_z = 1'b1; h_heads_w13_z = 1'b1;
    h_cyls = 16'd0;   h_cyls_hi_z = 1'b1;
    v_cookie_w = 4'd0; v_dof_w = 4'd0; v_cur_w24_z = 1'b1; v_cur_w25_hi = 7'd0;
    v_cur_lo = 41'd0; v_type_hi_z = 1'b1; v_type_lo_2 = 1'b0;
    v_csum_w32 = 16'd0; v_csum_w33 = 16'd0;
  end

  // ==== what the header says ====
  // The 32 header bytes, field by field, little-endian; word 0 is bytes 0-1, so a DWORD is
  // {high word, low word} in memory order. Each test is the full-width field's, read through
  // the captures above: a field outside its bound fails its test whatever its low bits are.

  // HeaderSize >= 32 and <= 1 MiB, and a whole number of sectors: the data must start on a
  // sector boundary the block port can name. (<= 1 MiB needs HeaderSize[31:21] == 0.)
  wire hdr_size_ok = h_hsize_hi_z && (h_hsize >= 21'd32) && (h_hsize <= 21'h10_0000) &&
                     (h_hsize[8:0] == 9'd0);
  wire hdr_sec_ok  = h_bps_lo_512 && h_bps_hi_z;
  // The geometry: each field non-zero and inside NP2kai's bounds (fdd/sxsihdd.c's format
  // check), which also keeps the multipliers 8x8 and 16x16 instead of 32x32.
  wire hdr_geom_ok = (h_spt != 8'd0) && h_spt_hi_z && h_spt_w11_z &&
                     (h_heads != 8'd0) && h_heads_hi_z && h_heads_w13_z &&
                     (h_cyls != 16'd0) && h_cyls_hi_z;

  wire hdr_valid = h_res0_z && h_res1_z && hdr_size_ok && hdr_sec_ok && hdr_geom_ok;

  // THE DRIVE THE SIZE TESTS READ: the probe's while one is in flight (its verdict), else the
  // drive whose probe starts next (its tail LBA). Drive 0 first when both wait.
  wire       start_unit = !probe_pending[0];
  wire       cur_unit   = probe_busy ? probe_unit : start_unit;
  wire [40:0] size_lo   = size_lo_r[cur_unit];
  wire        size_hi   = size_hi_r[cur_unit];

  // The raw image's capacity is pc9821_block_io's own rule, unchanged: floor(size/512),
  // saturating when the size does not fit 41 bits.
  wire [31:0] raw_cap = size_hi ? 32'hFFFFFFFF : size_lo[40:9];

  // An HDI's capacity: NP2kai's totals (cylinders x heads x sectors, at most 255 x 255 x 65535,
  // which fits 32 bits), clamped to the file's sectors after the header (0 when the header is
  // the whole file). Read only beside hdr_valid, under which HeaderSize is h_hsize and a whole
  // number of sectors.
  wire [15:0] geom_sh      = {8'd0, h_spt} * {8'd0, h_heads};
  wire [31:0] geom_sectors = {16'd0, geom_sh} * {16'd0, h_cyls};
  wire [31:0] hdr_secs     = {20'd0, h_hsize[20:9]};
  wire [31:0] file_secs    = (raw_cap > hdr_secs) ? raw_cap - hdr_secs : 32'd0;
  wire [31:0] hdr_cap      = (geom_sectors < file_secs) ? geom_sectors : file_secs;

  // ==== fixed-VHD footer (big-endian, the image's LAST sector) ====
  // A fixed VHD is data at offset 0 plus a 512-byte footer; the tail probe needs a file that
  // is a whole number of sectors and has at least a sector before the footer, and a sector
  // count the 32-bit engine LBA can name.
  wire        tail_ok  = !size_hi && (size_lo >= 41'd1024) && (size_lo[8:0] == 9'd0);
  wire [31:0] tail_lba = raw_cap - 32'd1;

  // The block port's 16-bit word carries the first byte in its LOW half, while every footer
  // field is big-endian: each word is byte-swapped as it is captured, and a field's most-
  // significant word is the lowest-numbered (the cookie is compared in memory order instead).
  function automatic [15:0] bswap16(input [15:0] w);
    begin bswap16 = {w[7:0], w[15:8]}; end
  endfunction
  wire [31:0] vhd_csum      = {bswap16(v_csum_w32), bswap16(v_csum_w33)};
  wire [15:0] a_buf_swap    = bswap16(a_buf_data);
  // "conectix" in memory order: c o n e c t i x, so word 0 = {o,c} etc.
  wire        vhd_cookie_ok = &v_cookie_w;
  // current size: its bits [63:41] must be clear, so the size tests read v_cur_lo.
  wire        vhd_cur_hi_z  = v_cur_w24_z && (v_cur_w25_hi == 7'd0);
  wire        vhd_ok = vhd_cookie_ok &&
                       (&v_dof_w) &&                              // fixed: no dynamic header
                       v_type_hi_z && v_type_lo_2 &&              // type 2; 3/4 = dynamic/differencing
                       (v_cur_lo[8:0] == 9'd0) && (v_cur_lo != 41'd0) && vhd_cur_hi_z &&
                       // current size + 512 <= the file size (a size past 41 bits always holds it)
                       (size_hi || ({1'b0, v_cur_lo} + 42'd512 <= {1'b0, size_lo})) &&
                       (vhd_csum == ~vhd_sum);                    // one's complement, checksum field excluded

  // ==== the drive's data port ====
  // The probe's words are the header's, never the drive's: they are captured above instead
  // of being forwarded into the ATA's one-sector buffer.
  assign buf_we   = a_buf_we && !probe_busy;
  assign buf_addr = a_buf_addr;
  assign buf_data = a_buf_data;

  assign a_req_read   = out_read;
  assign a_req_write  = out_write;
  assign a_req_lba    = out_lba;
  assign a_req_window = out_window;
  assign a_req_unit   = out_unit;

  assign busy = (|probe_pending) || probe_busy || ata_pend || ata_inflight;
  // A mount pulse per drive.
  wire [1:0] mnt = {img_mounted1, img_mounted};

  always @(posedge clk) begin
    // The two one-cycle request outputs to the engine, cleared unless an arm below sets them.
    out_read  <= 1'b0;
    out_write <= 1'b0;
    req_done  <= 1'b0;
    req_error <= 1'b0;

    if (!rst_n) begin
      // Only the transfers die with a reset: the mounted image, its capacity and its parsed
      // offset survive, because the host does not re-send the mount after an OSD reset.
      // A probe that was in flight is re-issued from the front (the engine's state was reset
      // under it).
      if (probe_busy) begin
        probe_pending[probe_unit] <= 1'b1;
        probe_kind[probe_unit]    <= 1'b0;
      end
      probe_busy   <= 1'b0;
      ata_pend     <= 1'b0;
      ata_inflight <= 1'b0;
    end else begin
      // ---- mount / eject, per drive ----
      for (int u = 0; u < 2; u = u + 1) begin
        if (mnt[u]) begin
          size_lo_r[u]  <= img_size[40:0];
          size_hi_r[u]  <= |img_size[63:41];
          readonly_r[u] <= img_readonly;
          if (img_size < 64'd512) begin
            // Eject, the sub-sector unmount every consumer in this core uses: no image.
            state[u]         <= H_IDLE;
            mounted_r[u]     <= 1'b0;
            capacity_r[u]    <= 32'd0;
            hdr_off[u]       <= 12'd0;
            probe_pending[u] <= 1'b0;
            // A request still queued here was issued against the image that is gone; answer
            // it with the error an ejected medium produces. An in-flight request is completed
            // by the engine's own eject abort (pc9821_block_io.sv's `eject`).
            if (ata_pend && (ata_pend_unit == (u != 0))) begin
              ata_pend  <= 1'b0;
              req_done  <= 1'b1;
              req_error <= 1'b1;
            end
          end else begin
            // A mount (or a replacement): not ready until the front (and, if not an HDI,
            // tail) probe has run.
            state[u]         <= H_PROBE;
            mounted_r[u]     <= 1'b0;
            capacity_r[u]    <= 32'd0;
            hdr_off[u]       <= 12'd0;
            probe_pending[u] <= 1'b1;
            probe_kind[u]    <= 1'b0;
          end
        end
      end

      // ---- capture the probe's words ----
      // Front probe: the HDI header's 16 words. Tail probe: the VHD footer's first 36 words
      // plus the running byte sum of the whole footer, with the checksum field (bytes 64-67 =
      // words 32/33) excluded from the sum before it is one's-complemented.
      if (a_buf_we && probe_busy) begin
        if (!probe_kind[probe_unit]) begin
          case (a_buf_addr)
            8'd0:  h_res0_z      <= (a_buf_data == 16'd0);
            8'd1:  h_res1_z      <= (a_buf_data == 16'd0);
            8'd4:  h_hsize[15:0] <= a_buf_data;
            8'd5:  begin h_hsize[20:16] <= a_buf_data[4:0]; h_hsize_hi_z <= (a_buf_data[15:5] == 11'd0); end
            8'd8:  h_bps_lo_512  <= (a_buf_data == 16'd512);
            8'd9:  h_bps_hi_z    <= (a_buf_data == 16'd0);
            8'd10: begin h_spt <= a_buf_data[7:0]; h_spt_hi_z <= (a_buf_data[15:8] == 8'd0); end
            8'd11: h_spt_w11_z   <= (a_buf_data == 16'd0);
            8'd12: begin h_heads <= a_buf_data[7:0]; h_heads_hi_z <= (a_buf_data[15:8] == 8'd0); end
            8'd13: h_heads_w13_z <= (a_buf_data == 16'd0);
            8'd14: h_cyls        <= a_buf_data;
            8'd15: h_cyls_hi_z   <= (a_buf_data == 16'd0);
            default: ;
          endcase
        end else begin
          case (a_buf_addr)
            8'd0:  v_cookie_w[0] <= (a_buf_data == 16'h6F63);
            8'd1:  v_cookie_w[1] <= (a_buf_data == 16'h656E);
            8'd2:  v_cookie_w[2] <= (a_buf_data == 16'h7463);
            8'd3:  v_cookie_w[3] <= (a_buf_data == 16'h7869);
            8'd8:  v_dof_w[0]    <= (a_buf_data == 16'hFFFF);
            8'd9:  v_dof_w[1]    <= (a_buf_data == 16'hFFFF);
            8'd10: v_dof_w[2]    <= (a_buf_data == 16'hFFFF);
            8'd11: v_dof_w[3]    <= (a_buf_data == 16'hFFFF);
            8'd24: v_cur_w24_z   <= (a_buf_data == 16'd0);
            8'd25: begin
              v_cur_w25_hi    <= a_buf_swap[15:9];
              v_cur_lo[40:32] <= a_buf_swap[8:0];
            end
            8'd26: v_cur_lo[31:16] <= a_buf_swap;
            8'd27: v_cur_lo[15:0]  <= a_buf_swap;
            8'd30: v_type_hi_z   <= (a_buf_data == 16'd0);
            8'd31: v_type_lo_2   <= (a_buf_swap == 16'd2);
            8'd32: v_csum_w32    <= a_buf_data;
            8'd33: v_csum_w33    <= a_buf_data;
            default: ;
          endcase
          if ((a_buf_addr != 8'd32) && (a_buf_addr != 8'd33))
            vhd_sum <= vhd_sum + {24'd0, a_buf_data[7:0]} + {24'd0, a_buf_data[15:8]};
        end
      end

      // ---- the mount probe: the engine is lent to one drive's probe at a time ----
      if ((|probe_pending) && !probe_busy && !ata_inflight && (state[start_unit] == H_PROBE)) begin
        out_read      <= 1'b1;
        out_write     <= 1'b0;
        out_lba       <= probe_kind[start_unit] ? tail_lba : 32'd0;
        out_window    <= 1'b0;
        out_unit      <= start_unit;
        probe_busy    <= 1'b1;
        probe_unit    <= start_unit;
        probe_pending[start_unit] <= 1'b0;
        if (probe_kind[start_unit]) vhd_sum <= 32'd0;
      end

      // ---- take a guest request (one deep) ----
      if ((req_read || req_write) && !ata_pend) begin
        ata_pend       <= 1'b1;
        ata_pend_write <= req_write;
        ata_pend_lba   <= req_lba;
        ata_pend_unit  <= req_unit;
      end

      // ---- hand a guest request to the engine, offset by its drive's HDI header ----
      if (ata_pend && !ata_inflight && !probe_busy && !(|probe_pending) &&
          (state[ata_pend_unit] == H_READY)) begin
        out_write         <= ata_pend_write;
        out_read          <= !ata_pend_write;
        out_lba           <= ata_pend_lba + {20'd0, hdr_off[ata_pend_unit]};
        out_window        <= 1'b1;
        out_unit          <= ata_pend_unit;
        ata_inflight      <= 1'b1;
        ata_pend          <= 1'b0;
      end

      // ---- the engine's one completion ----
      // A mount of the probed drive in the completing cycle replaces the image the probe's
      // sector came from, so that completion's format verdict is ignored and the restart above
      // runs instead. A guest request's completion is still forwarded: the ATA is waiting for
      // it in X_WAIT_BLOCK (or X_DRAIN) whichever image the engine served it from.
      if (a_req_done) begin
        if (probe_busy) begin
          probe_busy <= 1'b0;
          if (!mnt[probe_unit] && (state[probe_unit] == H_PROBE) && !probe_pending[probe_unit]) begin
            if (!probe_kind[probe_unit]) begin
              if (hdr_valid && !a_req_error) begin
                // HDI: the front header decides; the tail is never read.
                hdr_off[probe_unit]    <= h_hsize[20:9];
                capacity_r[probe_unit] <= hdr_cap;
                mounted_r[probe_unit]  <= 1'b1;
                state[probe_unit]      <= H_READY;
              end else if (tail_ok) begin
                // Not an HDI: read the last sector for a fixed-VHD footer.
                probe_kind[probe_unit]    <= 1'b1;
                probe_pending[probe_unit] <= 1'b1;
              end else begin
                // Too small/unaligned to hold a footer: the raw image.
                hdr_off[probe_unit]    <= 12'd0;
                capacity_r[probe_unit] <= raw_cap;
                mounted_r[probe_unit]  <= 1'b1;
                state[probe_unit]      <= H_READY;
              end
            end else begin
              if (vhd_ok && !a_req_error) begin
                hdr_off[probe_unit]    <= 12'd0;                 // a fixed VHD's data starts at 0
                capacity_r[probe_unit] <= v_cur_lo[40:9];
              end else begin
                // Dynamic/differencing or a bad footer: the raw image, as before.
                hdr_off[probe_unit]    <= 12'd0;
                capacity_r[probe_unit] <= raw_cap;
              end
              mounted_r[probe_unit] <= 1'b1;
              state[probe_unit]     <= H_READY;
            end
          end
        end else if (ata_inflight) begin
          ata_inflight <= 1'b0;
          req_done     <= 1'b1;
          req_error    <= a_req_error;
        end
      end
    end
  end

endmodule

`default_nettype wire
