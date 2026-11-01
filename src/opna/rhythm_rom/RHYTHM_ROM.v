// Rhythm sample ROM for the YM2608's ADPCM-A path, as `jtopna.v` instantiates
// it.
//
// THIS FILE IS OURS, not vendor code. Upstream PC88_MiSTer ships a Quartus
// megafunction-wizard wrapper for the same module, whose `init_file` is
// Yamaha's 8 KiB rhythm sample image (bass drum, snare, top cymbal, hi hat,
// tom, rim). This repository commits no copyrighted data (README.md,
// "Licensing": "No NEC, Yamaha or other copyrighted firmware is included"), so
// the image is deliberately ABSENT from the tree and arrives as a
// user-supplied runtime file instead.
//
// AN ALL-ZERO IMAGE IS NOT SILENCE. It was believed to be ("the ROM reads as
// all-zero ADPCM codes, which the decoder turns into silence"), and a pack
// built without the image shipped that way -- which is the owner's harsh
// percussion pop. An ADPCM-A all-zero nibble is code 0 at step 0, i.e. a +2
// delta every 18.5 kHz sample (jt10_adpcma_lut step 0 code 0 = 12'o0002), so
// the 12-bit accumulator RAMPS and wraps instead of resting at zero: measured
// on ymfm's own decoder, one drum over the zero image reaches peak 15,360 with
// up to +6,726 of DC, where the real image stays zero-mean and ends at 4-184.
// The graceful no-image state does not exist; a missing image is a loud,
// DC-carrying buzz with an abrupt cut on every trigger. Build the pack with
// the real image (tools/build_pack.py --rhythm, auto-detected from --dumps).
//
// An empty ROM needs no initialisation, and that is also what makes it
// elaborate. The first version of this file filled 8192 entries with a loop,
// and Quartus 17 refuses that ("Error (10106): Verilog HDL Loop error ...
// loop must terminate within 5000 iterations"). Removing the contents removes
// the loop; there is nothing left to elaborate over. Do not add an init back
// for the empty case: the image comes from the pack at runtime, not from an
// init_file, so the array must have no initial contents of its own.
//
// ---------------------------------------------------------------------------
// The read port (unchanged from upstream)
//
// `jtopna.v` drives address = adpcma_addr[12:0] and rden = ~adpcma_roe_n and
// expects the byte one clock later, which is what a block-RAM read gives. The
// memory holds 12-bit words (two bytes each) because the pack loader below
// presents a 16-bit word per transfer; the read muxes the addressed byte out
// of the word registered one clock after `address`, so the chip still sees
// exactly the byte-at-address-it-presented timing it saw before.
//
// Software that triggers the rhythm channel with no image does not hang: every
// address answers a byte (0x00), so jt08's ADPCM-A counters
// (jt08_adpcm_cnt.v:106-111 seed each drum a start address and its hard-coded
// end address; :149 stops the channel on `addr4[13:1] == end4`) always reach
// their end and stop. There is no handshake to wait on, so an absent image
// cannot stall the channel -- but it is NOT silence either: that 0x00 byte is
// ADPCM-A code 0 at step 0, a +2 delta per sample, so the channel produces the
// loud, DC-carrying sawtooth the header above describes instead (AGENTS.md
// "Firmware pack (runtime inputs)"; tools/build_pack.py warns on a zero region
// and tools/check_pack.py fails on one).
// ---------------------------------------------------------------------------
//
// ---------------------------------------------------------------------------
// The pack-loader write port (now wired)
//
// The samples come from the ROM pack, exactly as the font does: a runtime file
// the user supplies, not committed in the tree (README.md, "Licensing").
// `tools/build_pack.py` writes the region at:
//
//     pack offset 0x49000, 8192 bytes
//
// the free 8 KiB slot immediately after the extended ROM banks
// (0x31000-0x49000) and before the option-ROM slot (0x70000). `pc9821_rhythm_loader`
// streams that region into this port as the pack is downloaded, so the chip's
// ADPCM-A read port sees the samples without a second memory or an SDRAM read.
//
// The port is 16 bits wide because the pack download delivers one 16-bit word
// per transfer, while the chip reads bytes; one download word writes the two
// consecutive ROM bytes it carries. The source of the data, and the rule that a
// user-supplied image is the only source (no substitute), is stated once in
// tools/build_pack.py.
// ---------------------------------------------------------------------------

`default_nettype none

module RHYTHM_ROM (
    input  wire [12:0] address,   // read address (jtopna: adpcma_addr[12:0])
    input  wire        clock,
    input  wire        rden,      // read enable (jtopna: ~adpcma_roe_n)
    output wire [7:0]  q,         // byte one clock after the address

    // Pack-loader seam, driven by pc9821_rhythm_loader (through jtopna). `waddr`
    // is a word index: word W holds the bytes at ROM addresses 2W and 2W+1, low
    // byte first.
    input  wire        we,
    input  wire [11:0] waddr,
    input  wire [15:0] wdata
);

  // This design's M10K-inferring memory, the same module the text VRAM and the
  // character-generator store use. INIT_EN is left at 0: the array has no
  // initial contents, which is both the policy (no copyrighted data) and what
  // removes any elaboration loop over the image.
  wire [15:0] q_word;

  // The byte lane of the registered word. Registered on the same condition as
  // the RAM's own read so the two stay in step: when `rden` is low the RAM's
  // output holds and so does this, which is what keeps `q` unchanged across a
  // deasserted read enable.
  reg [0:0] byte_sel;
  always @(posedge clock)
    if (rden) byte_sel <= address[0];

  pc9821_dpram #(
      .AW (12),
      .DW (16)
  ) u_rom (
      // Port A: the loader's 16-bit write.
      .clock_a  (clock),
      .address_a(waddr),
      .data_a   (wdata),
      .wren_a   (we),
      .q_a      (),

      // Port B: the chip's read, carrying the read enable so that a deasserted
      // `rden` leaves `q` unchanged.
      .clock_b  (clock),
      .en_b     (rden),
      .address_b(address[12:1]),
      .data_b   (16'h0000),
      .wren_b   (1'b0),
      .q_b      (q_word)
  );

  assign q = byte_sel ? q_word[15:8] : q_word[7:0];

endmodule

`default_nettype wire
