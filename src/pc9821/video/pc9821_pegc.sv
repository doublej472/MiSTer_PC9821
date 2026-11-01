// PC-9821 PEGC register file: the 0xE0000 MMIO window as this machine exposes it,
// the mode/view state it exports, and the registered responder that answers CPU
// accesses to it.
//
// The window is visible only while the PEGC MMIO view is up (the 0x6A dat 0x21
// select, pc9821_crtc's mode2_256col), exactly as NP2kai installs memvgaio on
// 0xE0000 when VOPBIT_VGA is set (i386c/cpumem.c) and MAME selects
// m_pegc_mmio_view there (pc9821.cpp pc9821_video_ff_w). What lives where is
// NP2kai's memvgaio byte store (mem/memvga.c), the primary software reference:
//
//   0xE0004-0xE0007  mio1[0..3]: the packed window banks. Bank A (the 0xA8000
//                    window) is 0xE0004 and bank B (0xB0000) 0xE0006, four bits
//                    each; the capture says so too (docs/probes/PEGC.TXT's PPM
//                    rows read 0E0004/0E0006, and only 0E0006 moved under DOOM).
//   0xE0100          mode: BIT 0 ONLY is stored (NP2kai memvgaio_wr8 masks
//                    `value &= 0x1` on this register). 0 = packed-pixel
//                    (256-colour) windows, 1 = the plane engine's windows. No
//                    reference implements any other bit.
//   0xE0102          VRAM enable: bit 0 gates the flat 0xF00000 aperture
//                    (NP2kai memvgaf_rd8/wr8). The whole byte is stored and read
//                    back (NP2kai stores it unmasked); only bit 0 is consumed.
//   0xE0104-0xE011F  the plane ENGINE's control registers: stored as plain bytes
//                    and read back (NP2kai's mio2 is a byte array) but consumed
//                    by NOTHING here - the engine is ladder rung L3 and is
//                    deliberately not built.
//
// NOT MODELLED, deliberately: the pattern block
// 0xE0120-0xE019F (the engine's ROP pattern source; its two read views are engine
// semantics - NP2kai's arms there are width-restricted and self-disclaimed
// (io/pegc.c:11-12), MAME routes reads through the ROP bit-15 path - so this
// module answers 0x00 there, which is also NP2kai's own uncovered-position
// answer), and the plane engine's window transfers. Reads of every other offset
// in the 32 KiB window answer 0x00 and stores are dropped (NP2kai memvgaio_rd8's
// `return 0x00` default). THE READ-BACK SHAPE here is NP2kai's plain byte
// round-trip; MAME maps 0xE0100/0xE0102 WRITE-ONLY (pc9821.cpp pegc_mmio_map)
// and its engine registers byte-wise, so a read of 0xE0100/0xE0102 diverges
// (capture-pending - the pegcwatch probe cannot read 0xE0102, its one blind
// spot). The 256-colour PALETTE-port read-back has its own recorded divergence
// (NP2kai returns the bytes, MAME returns 0): see pc9821_crtc's mirror.
//
// The responder honours the subsystem's contract (pc9821_memory_subsystem): the
// accept and the response are SEPARATE cycles and the record outlives the accept.
// A line read (an icache fill through this window) answers the same dword four
// times as FOUR WORD BEATS on cpu_resp_valid: no reference models a 128-bit
// register read and no guest fetches instructions from 0xE0000, but a fill that
// never completes would hang the CPU, so the route answers rather than stalls.
// The beats ARE the word response repeated (no 128-bit `{4{cpu_dout}}`
// copy): the L1 gathers word N into line word N, and here every
// word of the line is this dword.

`default_nettype none

module pc9821_pegc (
    input  wire        clk,
    input  wire        reset,

    // The CPU's request, as pc9821_memory_subsystem presents it: a dword-aligned
    // address inside 0xE0000-0xE7FFF with byte enables.
    input  wire        cpu_valid,
    input  wire        cpu_write,
    input  wire        cpu_line_read,
    input  wire [14:0] cpu_addr,
    input  wire [31:0] cpu_din,
    input  wire [3:0]  cpu_be,
    output reg  [31:0] cpu_dout,
    output reg         cpu_ready,
    output reg         cpu_resp_valid,

    // The state the machine model consumes.
    output wire [3:0]  bank_a,      // 0xE0004 bits 3:0: the 0xA8000 window's bank
    output wire [3:0]  bank_b,      // 0xE0006 bits 3:0: the 0xB0000 window's bank
    output wire        plane_mode,  // 0xE0100 bit 0: 1 = the windows are the engine's
    output wire        vram_en      // 0xE0102 bit 0: the flat aperture is enabled
);

  // mio1[0..3] (0xE0004-0xE0007) and mio2[0..31] (0xE0100-0xE011F): NP2kai's two
  // byte arrays (vramop.mio1[4], vramop.mio2[0x100] - only the used prefixes are
  // kept; the pattern block above them is L3's). Plain bytes, no masking on the
  // way in except 0xE0100's bit-0 mask (NP2kai memvgaio_wr8).
  reg [7:0] mio1 [0:3];

  // mio2 (32 bytes) is held as 8 dwords in one block RAM. Nothing consumes mio2 but the
  // read-back and the two bits exported below (kept in their own flops), so the bytes
  // need no reset of their own: a per-dword `dirty` flop stands for "reads as zero", and a
  // store merges into the dword's old value (0 while clean), which is exactly the
  // reset-to-zero + byte-store result. The RAM's read address is cpu_addr
  // presented every cycle; the answer is used in S_ACCEPT, one cycle after S_IDLE saw
  // cpu_valid.
  (* ramstyle = "M10K, no_rw_check" *) reg [31:0] mio2_ram [0:7];
  reg [7:0]  mio2_dirty;
  reg [31:0] mio2_q;
  reg        plane_mode_r, vram_en_r;
  always @(posedge clk) mio2_q <= mio2_ram[cpu_addr[4:2]];

  wire [14:0] req_addr = cpu_addr & 15'h7FFC;   // the access's dword-aligned base

  // ---- the byte read function: NP2kai memvgaio_rd8's answer per byte offset ----
  // 0xE0004-0xE0007 is `off[14:2] == 1`; 0xE0100-0xE011F is `off[14:5] == 8`.
  function automatic [7:0] rd8(input [14:0] off);
    begin
      if      (off[14:2] == 13'd1) rd8 = mio1[off[1:0]];
      else                         rd8 = 8'h00;
    end
  endfunction

  // The dword read: mio1 bytes, the RAM's dword (clean = 0), or 0.
  wire [31:0] mio2_dw = mio2_dirty[req_addr[4:2]] ? mio2_q : 32'h0000_0000;
  wire [31:0] rd_dword = (req_addr[14:2] == 13'd1) ? {rd8(req_addr + 15'd3), rd8(req_addr + 15'd2), rd8(req_addr + 15'd1), rd8(req_addr + 15'd0)}
                       : (req_addr[14:5] == 10'd8) ? mio2_dw : 32'h0000_0000;

  // ---- the registered responder (the pc9821_open_bus shape) ----
  localparam [2:0] S_IDLE = 3'd0, S_ACCEPT = 3'd1,
                   S_RESPONSE = 3'd2, S_LINE = 3'd3, S_HOLD = 3'd4;
  reg [2:0] state;
  reg [1:0] line_beat;
  reg request_write, request_line;

  // The write lands on the accept edge, while the requester still holds the
  // request (the valid-hold contract: data is stable from launch to ready).
  wire write_accept = (state == S_ACCEPT) && request_write;

  // ---- the byte write: NP2kai memvgaio_wr8's store per byte lane ----
  wire        mio2_sel = (req_addr[14:5] == 10'd8);
  wire [2:0]  mio2_idx = req_addr[4:2];
  // 0xE0100 keeps bit 0 only (NP2kai: `value &= 0x1` under SUPPORT_PEGC).
  wire [31:0] mio2_din = {cpu_din[31:8], cpu_din[7:1] & {7{(mio2_idx != 3'd0)}}, cpu_din[0]};
  wire [3:0]  mio2_be  = cpu_be & {4{mio2_sel}};
  wire        mio2_wr  = write_accept && (|mio2_be);
  // Read-modify-write on one 32-bit port: mio2_q already holds this dword (read in S_IDLE,
  // the address held since), and a clean dword's old value is 0.
  wire [31:0] mio2_old = mio2_dirty[mio2_idx] ? mio2_q : 32'h0000_0000;
  wire [31:0] mio2_new = {mio2_be[3] ? mio2_din[31:24] : mio2_old[31:24],
                          mio2_be[2] ? mio2_din[23:16] : mio2_old[23:16],
                          mio2_be[1] ? mio2_din[15:8]  : mio2_old[15:8],
                          mio2_be[0] ? mio2_din[7:0]   : mio2_old[7:0]};
  always @(posedge clk) if (mio2_wr) mio2_ram[mio2_idx] <= mio2_new;

  integer lane;
  always @(posedge clk) begin
    if (reset) begin
      for (lane = 0; lane < 4; lane = lane + 1) mio1[lane] <= 8'h00;
      mio2_dirty <= 8'h00;
      plane_mode_r <= 1'b0;
      vram_en_r <= 1'b0;
    end else if (write_accept) begin
      for (lane = 0; lane < 4; lane = lane + 1) begin : wr_lane
        if (cpu_be[lane] && (req_addr[14:2] == 13'd1))
          mio1[lane] <= cpu_din[lane*8 +: 8];
      end
      if (mio2_wr) begin
        mio2_dirty[mio2_idx] <= 1'b1;
        if (mio2_idx == 3'd0 && mio2_be[0]) plane_mode_r <= cpu_din[0];
        if (mio2_idx == 3'd0 && mio2_be[2]) vram_en_r    <= cpu_din[16];
      end
      // every other offset: the store is dropped (memvgaio_wr8 falls through)
    end
  end

  always @(posedge clk) begin
    if (reset) begin
      state <= S_IDLE;
      line_beat <= 2'd0;
      request_write <= 1'b0;
      request_line <= 1'b0;
      cpu_dout <= 32'h0000_0000;
      cpu_ready <= 1'b0;
      cpu_resp_valid <= 1'b0;
    end else begin
      cpu_ready <= 1'b0;
      cpu_resp_valid <= 1'b0;
      case (state)
        S_IDLE: if (cpu_valid) begin
          request_write <= cpu_write;
          request_line <= cpu_line_read;
          state <= S_ACCEPT;
        end
        S_ACCEPT: begin
          cpu_ready <= 1'b1;
          // The read data is captured ON the accept edge, so the response cycle
          // carries a settled value (the responder contract's separate cycles).
          if (!request_write) begin
            cpu_dout <= rd_dword;
          end
          state <= request_write ? S_HOLD : S_RESPONSE;
        end
        S_RESPONSE: begin
          // A word read answers here; a line read's four beats start the cycle after.
          if (request_line) begin
            line_beat <= 2'd0;
            state <= S_LINE;
          end else begin
            cpu_resp_valid <= 1'b1;
            state <= S_HOLD;
          end
        end
        // One beat per cycle, the same dword every time (cpu_dout, held since the accept).
        S_LINE: begin
          cpu_resp_valid <= 1'b1;
          line_beat <= line_beat + 2'd1;
          if (line_beat == 2'd3) state <= S_HOLD;
        end
        // One cycle only: never wait for cpu_valid to drop (the responder contract).
        S_HOLD: state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
    end
  end

  // A line read repeats the dword (see the header) as four cpu_resp_valid beats, in S_LINE:
  // there is no line register and no 128-bit copy of cpu_dout to mux.

  assign bank_a     = mio1[0][3:0];
  assign bank_b     = mio1[2][3:0];
  assign plane_mode = plane_mode_r;
  assign vram_en    = vram_en_r;

endmodule

`default_nettype wire
