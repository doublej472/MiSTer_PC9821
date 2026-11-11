// OPNA with JT12

module jtopna (
    input           rst,
    input           clk,
    input           cen,
    input   [7:0]   din,
    input   [1:0]   addr,
    input           cs_n,
    input           wr_n,
    input           rd_n,

    output  [7:0]   dout,
    output          irq_n,
    // GPIO
    input   [7:0]   IOA_in,
    input   [7:0]   IOB_in,
    output  [7:0]   IOA_out,
    output  [7:0]   IOB_out,
    output          IOA_oe,
    output          IOB_oe,
    // ADPCM
    output  [17:0]  adpcm_addr,
    output          adpcm_roe,
    input   [7:0]   adpcm_din,
    output          adpcm_wr,
    output  [7:0]   adpcm_dout,
    // Output
    output  signed  [19:0] fm_snd_right,
    output  signed  [19:0] fm_snd_left,
    output          [11:0] psg_snd,
    // LOCAL CHANGE -- everything else in this file is upstream's, byte for byte.
    // These three inputs are the only difference. They wire the write port the
    // RHYTHM_ROM instance below always exposed (upstream leaves it unconnected,
    // so `we` was tied to 0); pc9821_opna drives them from
    // pc9821_rhythm_loader. See src/opna/rhythm_rom/RHYTHM_ROM.v and
    // src/opna/LICENSE-SCOPE.md.
    input           rhythm_we,
    input   [11:0]  rhythm_waddr,
    input   [15:0]  rhythm_wdata,
    // LOCAL CHANGE (B-4, this repository): 0xA460 bit 0 dropping switches the
    // FM to NP2kai's 3-channel mono configuration (cbus/board86.c:79-94).
    input           ch3_mono,
    // LOCAL CHANGE (flag-reset seam, this repository): the board glue's timer flag
    // reset, a one-clk pulse per flag ([0] timer A, [1] timer B) on the guest's data
    // write that resets it (0x27 bit 4/5, or 0x110 bit 7). The chip resets the flag at
    // the bus write (ymfm ymfm_fm.ipp engine_mode_write `set_reset_status(0, reset_mask);`,
    // ymfm_opn.cpp ym2608::write_data `m_fm.set_reset_status(0, 0xff);`; NP2kai
    // sound/opntimer.c opna_settimer `opna->s.status &= ~((cData & 0x30) >> 4);`), but
    // the glue feeds the register port through a queue (pc9821_opna.sv), so the reset
    // comes in here at the write instead and the queued copy no longer carries it.
    // [1] is also held high, a level, while the guest's 0x110 Timer-B mask (bit 1)
    // stands: a real Xe10 keeps that flag clear under the mask while the timer runs
    // (pc9821_opna.sv tmr_mask_b, docs/probes/KIT1-XE10-OPNA.TXT STATUS3).
    input   [1:0]   host_clr_tmr,
    // The same seam's timer registers (0x24-0x26, 0x27 bits 3-0) as the glue latched them
    // at the guest's write: {value_A[9:0], value_B[7:0], enable B, enable A, load B,
    // load A}; see jt12_top.v.
    input   [21:0]  host_tmr
);

// ADPCM-A
wire [19:0] adpcma_addr;
wire        adpcma_roe_n;   // ADPCM-A ROM output enable
wire  [7:0] adpcma_data;    // Data from RAM
// INTERNAL
wire [12:0] rom_addr;
wire        rden;

// ADPCM-B
wire [23:0] adpcmb_addr;
wire        adpcmb_roe_n;
wire        adpcmb_wr_n;

// assign external pin
assign      adpcm_addr  = adpcmb_addr[17:0];
assign      adpcm_roe   = ~adpcmb_roe_n;
assign      adpcm_wr    = ~adpcmb_wr_n;

// assign internal signal
assign      rom_addr    = adpcma_addr[12:0];
assign      rden        = ~adpcma_roe_n;

// JT08 module
jt08 u_jt08(
    .rst            ( rst          ),
    .clk            ( clk          ),
    .cen            ( cen          ),
    // The ADPCM-A drum-bus gain is hard-wired at 0 (the 0 dB default, bit-identical
    // to upstream at 0). The vendored jt12 tree keeps its gain input unmodified.
    .rhythm_gain_shift ( 3'd0 ),
    .din            ( din          ),
    .addr           ( addr         ),
    .cs_n           ( cs_n         ),
    .wr_n           ( wr_n         ),
    .rd_n           ( rd_n         ),

    .dout           ( dout         ),
    .irq_n          ( irq_n        ),
    // YM2203 I/O pins
    .IOA_in         ( IOA_in       ),
    .IOB_in         ( IOB_in       ),
    .IOA_out        ( IOA_out      ),
    .IOB_out        ( IOB_out      ),
    .IOA_oe         ( IOA_oe       ),
    .IOB_oe         ( IOB_oe       ),
    // ADPCM pins
    .adpcma_addr    ( adpcma_addr  ),
    .adpcma_roe_n   ( adpcma_roe_n ),
    .adpcma_data    ( adpcma_data  ),
    .adpcmb_addr    ( adpcmb_addr  ),
    .adpcmb_roe_n   ( adpcmb_roe_n ),
    .adpcmb_din     ( adpcm_din    ),
    .adpcmb_wr_n    ( adpcmb_wr_n  ),
    .adpcmb_dout    ( adpcm_dout   ),
    // Separated output
    .psg_A          (              ),
    .psg_B          (              ),
    .psg_C          (              ),
    .fm_snd_left    ( fm_snd_left  ),
    .fm_snd_right   ( fm_snd_right ),
    .ch3_mono       ( ch3_mono     ),
    .host_clr_tmr   ( host_clr_tmr ),   // LOCAL CHANGE (flag-reset seam)
    .host_tmr       ( host_tmr     ),   // LOCAL CHANGE (flag-reset seam)
    // Sound output
    .psg_snd        ( psg_snd      ),
    .snd_left       (              ),
    .snd_right      (              ),
    .snd_sample     (              )
);

RHYTHM_ROM u_rhythm_rom (
    .address    ( rom_addr      ),
    .clock      ( clk           ),
    .rden       ( rden          ),
    .q          ( adpcma_data   ),
    // LOCAL CHANGE -- the three lines below are the seam the ROM above always
    // exposed. Everything else in this file is upstream's.
    .we         ( rhythm_we     ),
    .waddr      ( rhythm_waddr  ),
    .wdata      ( rhythm_wdata  )
);

endmodule
