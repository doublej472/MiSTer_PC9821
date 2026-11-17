/* This file is part of JT12.


    JT12 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT12 program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT12.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 21-03-2019
*/

// Local changes in this file (src/opna/LICENSE-SCOPE.md, "Upstream"):
//   * LOCAL FIX (PC-98 core, BRDY after a flag reset): a flag reset's BRDY clear holds past
//     the next status read instead of one clk_en, outside playback (at the flags below).

module jt08_adpcm_drvB(
    input           rst_n,
    input           clk,
    input           cen,      // 8MHz cen
    input           cen55,    // clk & cen55  =  55 kHz
    // Control
    input           acmd_on_b,  // Control - Process start, Key On
    input           acmd_rep_b, // Control - Repeat
    input           acmd_rst_b, // Control - Reset
    input           acmd_up_b,  // Control - New command received
    input           acmd_mem_b, // Control - Access external RAM
    input           acmd_rec_b, // Control - Record
    input           acmd_x8_b,  // Control - Address granularity is 8b
    input           acmd_rom_b, // Control - External memory is ROM
    input    [ 1:0] alr_b,      // Left / Right
    input    [15:0] astart_b,   // Start address
    input    [15:0] aend_b,     // End   address
    input    [15:0] adeltan_b,  // Delta-N
    input    [ 7:0] aeg_b,      // Envelope Generator Control
    input    [15:0] alimit_b,   // Limit address
    output reg [ 3:0] flag,
    input      [ 3:0] clr_flag,
    // memory
    output reg [23:0] addr,
    input      [ 7:0] ram_din,
    output reg [ 7:0] ram_dout,
    output reg        ram_oe_n,
    output reg        ram_wr_n,
    // cpu bus
    input      [ 7:0] bus_din,
    output reg  [7:0] bus_dout,
    input             sel_ram,
    input             wr_n,
    input             rd_n,

    output reg signed [15:0]  pcm55_l,
    output reg signed [15:0]  pcm55_r
);

wire nibble_sel;
wire adv;           // advance to next reading
wire clr_dec;
wire chon;
wire dsign;
wire [15:0] deltax;

// `ifdef SIMULATION
// real fsample;
// always @(posedge acmd_on_b) begin
//     fsample = adeltan_b;
//     fsample = fsample/65536;
//     fsample = fsample * 55.5;
//     $display("\nINFO: ADPCM-B ON: %X delta N = %6d (%2.1f kHz)", astart_b, adeltan_b, fsample );
// end
// `endif

// state
localparam  STATE_IDLE  = 'd0,
            STATE_READ  = 'd1,
            STATE_WAIT1 = 'd2,
            STATE_POST  = 'd3,
            STATE_WAIT2 = 'd4,
            STATE_WRITE = 'd5,
            STATE_WRITE2= 'd6,
            STATE_END   = 'd8;

// bit assign for flag
localparam  F_EOS   = 0,
            F_BRDY  = 1,
            F_ZERO  = 2,
            F_BUSY  = 3;

// wait
//localparam  RDWAIT  = 3;
localparam  RDWAIT  = 4;    // for PC88_MiSTer (add 1 wait due to memory access conflict with FDD)
localparam  WRWAIT  = 2;

reg   [2:0] state;
reg [RDWAIT:0] waits;       // indicate wait cycle for RAM read
reg         fread1;         // indicate 1st dummy read

reg  [15:0] pre_start_b;    // previous astart_b: detect change
reg         dsel;           // latch nibble_sel

reg  [20:0] ram_addr;
reg         ram_busy, ram_eos;
wire [20:0] pcm_addr;
wire        pcm_eos;

// set addresses with 8b/1b granularity
wire        gran_8b = (acmd_x8_b | acmd_rom_b);
wire [20:0] astart  = (gran_8b) ? {astart_b, 5'h00} : {3'h0, astart_b, 2'h0} ;
wire [20:0] astop   = (gran_8b) ? {aend_b,   5'h1F} : {3'h0, aend_b,   2'h3} ; 
wire [20:0] alimit  = (gran_8b) ? {alimit_b, 5'h1F} : {3'h0, alimit_b, 2'h3} ;

// LOCAL FIX (PC-98 core, BRDY after a flag reset): the events that set BRDY (see the flags).
reg        acmd_up_q;
reg  [1:0] brdy_hold;     // 55.5 kHz enables still to pass after a flag reset before the idle set
wire       brdy_idle = !acmd_rst_b && !ram_busy && (brdy_hold == 2'd0);
wire       brdy_set  = acmd_on_b ? ~ram_busy :
                       ((cen && acmd_mem_b && (state == STATE_POST)) || (acmd_up_b && !acmd_up_q) ||
                        brdy_idle);
always @(posedge clk) begin
    acmd_up_q <= acmd_up_b;
    brdy_hold <= clr_flag[F_BRDY] ? 2'd2 :
                 (cen55 && (brdy_hold != 2'd0)) ? (brdy_hold - 2'd1) : brdy_hold;
end

always @(posedge clk) begin
    if ((rst_n == 1'b0) || (acmd_rst_b)) begin
        state       <= STATE_IDLE;
        pre_start_b <= 16'd0;
        ram_addr    <= 21'd0;
        ram_busy    <= 1'b0;
        ram_eos     <= 1'b0;
        ram_wr_n    <= 1'b1;
        ram_oe_n    <= 1'b1;
        bus_dout    <= 8'd0;
        ram_dout    <= 8'd0;
        waits       <= {RDWAIT+1{1'b0}};
        fread1      <= 1'b1;
        addr        <= 24'd0;
        din         <= 4'd0;
    end else if (cen) begin
        if (acmd_mem_b) begin
            // ram access mode
            casez (state)
                STATE_IDLE: begin
                    if (astart_b != pre_start_b) begin
                        ram_addr<= astart;
                        ram_eos <= 1'b0;
                        fread1  <= 1'b1;
                    end
                    if ((sel_ram) && (!acmd_on_b)) begin
                        // Access external memory
                        if (acmd_rec_b & !wr_n) begin
                            state   <= STATE_WRITE;
                            ram_oe_n<= 1'b1;
                            ram_busy<= 1'b0;
                        end else if (!rd_n) begin
                            // (start READ sequence here)
                            state   <= STATE_WAIT1;
                            ram_oe_n<= 1'b0;
                            ram_busy<= 1'b1;
                            waits   <= {1'b1, {RDWAIT{1'b0}}};
                        end
                        addr    <= { 3'b000, ram_addr};
                    end else if (acmd_on_b & adv & cen55) begin
                        // Playing ADPCM
                        // (start READ sequence here)
                        state   <= STATE_WAIT1;
                        addr    <= { 3'b000, pcm_addr};
                        dsel    <= nibble_sel;
                        ram_busy<= 1'b1;
                        ram_oe_n<= 1'b0;
                        waits       <= {1'b1, {RDWAIT{1'b0}}};
                    end else begin
                        state   <= STATE_IDLE;
                        addr    <= addr;
                        ram_busy<= 1'b0;
                        ram_oe_n<= 1'b1;
                    end
                    // save previous one
                    pre_start_b <= astart_b;
                    // strobe control
                    ram_wr_n    <= 1'b1;
                end
                STATE_WRITE: begin
                    ram_oe_n    <= 1'b1;
                    ram_busy    <= 1'b1;
                    ram_wr_n    <= 1'b0;
                    // Latch CPU data
                    ram_dout    <= bus_din;
                    // State switch to External write cycle:
                    //
                    // There are several clocks between latching the data
                    // and outputting it to the external RAM,
                    // but these will be omitted.
                    waits       <= {{RDWAIT+1{1'b1}}, {WRWAIT{1'b0}}};
                    state       <= STATE_WRITE2;
                end
                STATE_WRITE2: begin
                    // write cycle for external memory with wait
                    ram_busy    <= 1'b1;
                    waits       <= {1'b1, waits[RDWAIT:1]};
                    if (waits[0]) begin
                        state   <= STATE_POST;
                    end else begin
                        state   <= STATE_WRITE2;
                    end
                end
                STATE_WAIT1: begin
                    // wait state for external memory READ
                    ram_busy    <= 1'b1;
                    waits       <= {1'b1, waits[RDWAIT:1]};
                    if (waits[0] && ~sel_ram) begin
                        state   <= STATE_POST;
                    end else begin
                        state   <= STATE_WAIT1;
                    end
                end
                STATE_POST: begin
                    // end strobe
                    ram_oe_n    <= 1'b1;
                    ram_wr_n    <= 1'b1;
                    // data
                    bus_dout    <= ram_din;
                    din         <= !dsel ? ram_din[7:4] : ram_din[3:0];
                    // next address (access external mem)
                    if (!acmd_on_b) begin 
                        if (ram_addr == astop) begin
                            ram_addr<= astart;
                            ram_eos <= 1'b1;
                        end else if (ram_addr == alimit) begin
                            ram_addr<= 21'd0;
                        end else if ((!acmd_rec_b) && (fread1)) begin
                            // end of 1st dummy read
                            fread1 <= 1'b0;
                        end else begin
                            ram_addr<= ram_addr + 21'd1;
                        end
                    end
                    // state
                    ram_busy    <= 1'b0;
                    if (!sel_ram) begin
                        state   <= STATE_IDLE;
                    end else begin
                        state   <= STATE_WAIT2;
                    end
                end
                STATE_WAIT2: begin
                    // post wait state
                    ram_busy    <= 1'b0;
                    if (!sel_ram) begin
                        state   <= STATE_IDLE;
                    end else begin
                        state   <= STATE_WAIT2;
                    end
                end
                default: state  <= STATE_IDLE;
            endcase
        end else begin
            // cpu memory mode
            state       <= STATE_IDLE;
            ram_addr    <= astart;
            fread1      <= 1'b1;
            pre_start_b <= astart_b;
            ram_busy    <= 1'b0;
            ram_eos     <= 1'b0;
            ram_wr_n    <= 1'b1;
            ram_oe_n    <= 1'b1;
            bus_dout    <= 8'd0;
            ram_dout    <= 8'd0;
        end
    end
    // flags
    // LOCAL FIX (PC-98 core, BRDY after a flag reset): upstream sets BRDY whenever the memory
    // port is idle (`flag[F_BRDY] | ( ~ram_busy )`), so a 0x110 = 80 flag reset clears it for
    // one clk_en and it is back before the guest can read it. On the Xe10 the reset's clear is
    // what the next read sees: after a 0x100 = 01 reset and after each of the last five resets
    // in memory-write mode the first status read finds BRDY clear (docs/probes/
    // XE10T-XE10-OPNA2.TXT `ADB_SETUP st0=00 s_rst=08 sb=08 st1=00 stl=00 reads=1`, `FR_ADB
    // i=3 sb=08 st1=00 stl=00 reads=1` .. `i=7`). The same rows show BRDY set again:
    //   * by a 0x100 write (`s_rst=08` right after 0x100 = 01, `s_set=08` after the set-up;
    //     ymfm ymfm_adpcm.cpp adpcm_b_channel::write sets STATUS_BRDY on a 0x00 write);
    //   * by each memory byte (ADB_W, 40 of 40; ymfm write_ram/read_ram
    //     `set_reset_status(STATUS_BRDY);`), here the end of a CPU access (STATE_POST);
    //   * on its own while the unit is idle and not held in reset (0x100 bit 0 clear): each
    //     FR_ADB row's first read before its reset (`sb=08`) follows a row that had left it
    //     clear, with nothing written, and kit 1 reads it back as soon as 0x110 unmasks it
    //     with 0x100 = 00 (docs/probes/KIT1-XE10-OPNA.TXT `C0 0188=00 018C=08`,
    //     tb_pc9821_opna_kit1). With 0x100 = 01 it did not come back before the set-up
    //     (ADB_SETUP `stl=00`, then `s_set=08` after the 0x100 = 60 write). The capture bounds
    //     WHEN only: later than the first read after the reset, sooner than the next row. Here
    //     the idle port sets it again from the second 55.5 kHz sample enable after the reset
    //     (18-36 us, the unit's own rate), inside those bounds; the instant is not measured.
    // Power-up is the idle case (ymfm `m_status(STATUS_BRDY)`), once the reset's clear is over.
    // During playback (acmd_on_b) upstream's rule is kept: no capture covers it. Not reproduced:
    // after the EOS rows the machine kept BRDY (and, at the first read, EOS) through three
    // resets (FR_ADB i=0..2 time out at 4096 reads); no reference explains it (todo item 38).
    flag[F_BRDY] <= clr_flag[F_BRDY] ? 1'b0 : (flag[F_BRDY] | brdy_set);
    flag[F_EOS]  <= clr_flag[F_EOS]  ? 1'b0 : (flag[F_EOS] | (~acmd_on_b & ram_eos) | (acmd_on_b & pcm_eos));
    flag[F_ZERO] <= 1'b0; //clr_flag[F_ZERO] ? 1'b0 : adc_zero;
    flag[F_BUSY] <= clr_flag[F_BUSY] ? 1'b0 : chon;
    // clear internal flag
    if (clr_flag[F_EOS]) begin
        ram_eos <= 1'b0;
    end 
end

jt08_adpcmb_cnt u_cnt(
    .rst_n       ( rst_n           ),
    .clk         ( clk             ),
    .cen         ( cen55           ),
    .delta_n     ( adeltan_b       ),
	.acmd_up_b   ( acmd_up_b       ),
    .clr         ( acmd_rst_b      ),
    .on          ( acmd_on_b       ),
    .astart      ( astart          ),
    .aend        ( astop           ),
    .arepeat     ( acmd_rep_b      ),
    .alimit      ( alimit          ),
    .addr        ( pcm_addr        ),
    .nibble_sel  ( nibble_sel      ),
    // Flag control
    .chon        ( chon            ),
    .clr_flag    ( clr_flag[F_EOS] ),
    .flag        ( pcm_eos         ),
    .clr_dec     ( clr_dec         ),
    .adv         ( adv             )
);

reg [3:0] din;

wire signed [15:0] pcmdec, pcminter, pcmgain;

jt10_adpcmb u_decoder(
    .rst_n  ( rst_n          ),
    .clk    ( clk            ),
    .cen    ( cen            ),
    .adv    ( adv & cen55    ),
    .data   ( din            ),
    .chon   ( chon           ),
    .clr    ( clr_dec        ),
    .dsign  ( dsign          ),
    .dx     ( deltax         ),
    .pcm    ( pcmdec         )
);

`ifndef NOBINTERPOL
jt08_adpcmb_interpol u_interpol(
    .rst_n  ( rst_n          ),
    .clk    ( clk            ),
    .cen    ( cen            ),
    .cen55  ( cen55          ),
    .adv    ( adv            ),
    .deltan ( adeltan_b      ),
    .dsign  ( dsign          ),
    .deltax ( deltax         ),
    .pcmdec ( pcmdec         ),
    .pcmout ( pcminter       )
);
`else 
assign pcminter = pcmdec;
`endif

jt10_adpcmb_gain u_gain(
    .rst_n  ( rst_n          ),
    .clk    ( clk            ),
    .cen55  ( cen55          ),
    .tl     ( aeg_b          ),
    .pcm_in ( pcminter       ),
    .pcm_out( pcmgain        )
);

always @(posedge clk) if(cen55) begin
    pcm55_l <= alr_b[1] ? pcmgain : 16'd0;
    pcm55_r <= alr_b[0] ? pcmgain : 16'd0;
end

endmodule // jt08_adpcm_drvB
