// Streams the user-supplied YM2608 ADPCM-A rhythm image out of the ROM pack into RHYTHM_ROM's
// write port as the pack is downloaded.
// The image is Yamaha's data, so this repository never commits it; it is a runtime file the user
// drops in, like the BIOS, the font and SOUND.ROM (README.md, "Licensing": "No NEC, Yamaha or
// other copyrighted firmware is included"). tools/build_pack.py places it at offset 0x49000, 8192 bytes, zero-filling it when
// no image is supplied; its docstring owns the pack layout and the priority rule.
// The download delivers one 16-bit word per ioctl_wr at an even byte address, which is why
// RHYTHM_ROM is word-addressed: one in-region ioctl_wr is one ROM-word write at byte
// (ioctl_addr - RHYTHM_PACK_OFFSET), with no byte-splitting state machine.
// This module observes the shared stream only: it owns nothing and never suppresses a write, and
// `reset` clears the idle outputs only.

`default_nettype none

module pc9821_rhythm_loader #(
    parameter [15:0] IOCTL_INDEX = 16'd0,
    parameter [26:0] RHYTHM_PACK_OFFSET = 27'h0049000,
    parameter integer RHYTHM_BYTES = 8192
) (
    input wire clk,
    input wire reset,

    // The shared ROM-pack download stream (pc9821_system's ioctl_* ports).
    input wire        ioctl_download,
    input wire [15:0] ioctl_index,
    input wire        ioctl_wr,
    input wire [26:0] ioctl_addr,
    input wire [15:0] ioctl_dout,

    // RHYTHM_ROM's pack-loader write port.
    output reg         we,
    output reg  [11:0] waddr,
    output reg  [15:0] wdata
);

  wire selected = ioctl_download && (ioctl_index == IOCTL_INDEX);

  // Offset inside the region, and the guard that keeps an address below the
  // region from wrapping into it. `offset` is a byte offset; the ROM word index
  // is offset/2, and RHYTHM_BYTES is even, so bit 0 is always 0.
  wire [26:0] offset   = ioctl_addr - RHYTHM_PACK_OFFSET;
  wire        in_region = selected && (ioctl_addr >= RHYTHM_PACK_OFFSET) &&
                          (offset < RHYTHM_BYTES[26:0]);
  wire        write     = ioctl_wr && in_region;

  always @(posedge clk) begin
    we <= write;
    if (reset && !write) begin
      waddr <= 12'd0;
      wdata <= 16'd0;
    end else begin
      waddr <= offset[12:1];
      wdata <= ioctl_dout;
    end
  end

endmodule

`default_nettype wire
