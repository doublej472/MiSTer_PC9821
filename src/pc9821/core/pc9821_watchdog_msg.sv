// The stall-watchdog telemetry record: ONE line, one character at a time.

// THE SHAPE IS THE CONTRACT. One line, LF-terminated, 351 bytes, and the second-to-last
// byte says which of three states this is. pc9821_wdg_trigger.sv selects it, pc9821_system.sv
// substitutes it at the index below, tools/decode_telemetry.py reads this map:
//   'W' a WEDGE: a request is OUTSTANDING and nothing COMPLETED for 200 ms. The machine stopped.
//   'S' IDLE: no request at all for 200 ms - halted or in a long I/O wait, usually healthy.
// 'P' the 2 s heartbeat, which a running machine emits too, so it proves NOTHING.
// NO CARRIAGE RETURNS, AND THAT IS THE FIX FOR THE BLANK LINE: a tty's ICRNL maps CR to LF on the
// way into a capture, so a CR LF break arrives as TWO newlines under a tty's ICRNL. A bare LF is
// one newline under any line discipline.
// 214 bytes are literal ROM text and 137 come from the selector below; a literal is never 0x00, so
// the ROM's 0x00 marks a selector byte, and index 349 holds '?', the trigger's placeholder. NEW
// FIELDS GO BEFORE T, NEVER AFTER IT: the trigger must stay the byte immediately after T=<2hex>
// (tools/decode_telemetry.py's PATH_RE finds it there, and the '?' placeholder check compares its
// offset to the T field's end), and appending ahead of T keeps every earlier field's index - the
// two benches that read a field BY INDEX and this record's own coordinate check are then untouched
// by an extension. HP (the last completed HPS block transfer's cycles) was added that way, and so
// were the STORAGE fields: FST/FCM/FRS/FCH (the FDC's state, command, last result and sector in
// flight, pc9821_fdc's dbg taps) and ALB/ASE (the ATA's transfer LBA and {sector_count,
// error_reg}, pc9821_ata's dbg_lba/dbg_sec), the only devices whose failures were invisible in a
// capture.
//
// THE FIELDS ARE A SNAPSHOT, taken at the report's accept (the `snap` input, shared with
// pc9821_perf_msg/pc9821_gfx_msg): each field's digits are separate byte transfers on the same
// paced FIFO the PRF/GFX records use, so read live they would sample different times and a carry
// crossing between two digits of one field splices two values into a torn composite. `snap` latches every field once and the nib
// selector reads the held copies, so the whole record is one instant however long the emission
// waits.
`default_nettype none

module pc9821_watchdog_msg (
    input         clk,
    input         snap,                 // one pulse at the report's accept: latch the fields
    input  [ 8:0] idx,                  // 0..350: the message is 351 bytes, ONE record line
    input  [15:0] cpu_cs, // W: the stall, the drive, the GDC window, the video and the ATA counters
    input  [31:0] cpu_eip,
    input  [7:0] io_debug_status,
    input         triple_fault_reset,
    input         hdd_mounted,
    input  [31:0] hdd_capacity,
    input         gdc_disp,
    input  [7:0] vid_frame_cnt,
    input  [7:0] hdd_req_cnt,
    input  [7:0] hdd_err_cnt,
    input         hdd_busy,
    input  [31:0] hdd_hps_cycles,   // HP: the last completed HPS block transfer's cycles
    input         vid_lit_seen,
    input  [7:0] vid_lit_cnt,
    input  [7:0] ata_dbg_state,
    input  [31:0] ata_dbg_cmd,   // ATA: {aborts, last command, commands, reason} - all four parts
    // ALB/ASE: the ATA's transfer context (pc9821_ata's dbg_lba/dbg_sec) - the LBA the
    // in-flight or last transfer started at, and the task file's {sector_count, error_reg}.
    input  [31:0] ata_dbg_lba,
    input  [15:0] ata_dbg_sec,
    // FST/FCM/FRS/FCH: the FDC's own diagnostics (pc9821_fdc's dbg taps, through
    // pc9821_iobus): {IRQ, DRQ, st, x_st}, the last command byte, the last result word
    // {res0, res1, res2, exec_st0}, and the CHRN of the sector in flight.
    input  [7:0]  fdc_dbg_state,
    input  [7:0]  fdc_dbg_cmd,
    input  [31:0] fdc_dbg_result,
    input  [31:0] fdc_dbg_chrn,
    input  [3:0] io_dbg_gate,
    input         mounted_at_run,
    input  [15:0] gdc_dbg_sad, // the GDC window the guest programmed
    input  [7:0] gdc_dbg_pitch,
    input         gdc_dbg_col40,
    input         gdc_dbg_disp,
    input  [7:0] kbd_dbg_events, // the keyboard chain
    input  [7:0] kbd_dbg_delivered,
    input  [7:0] kbd_dbg_rd_data,
    input  [7:0] kbd_dbg_wr_ctrl,
    input         kbd_dbg_rts,
    input         kbd_dbg_rx_en,
    input         kbd_irq,       // reported ONCE, as IRQ
    input  [7:0] kbd_dbg_last_del,
    input  [7:0] kbd_dbg_ctrl0,
    input  [7:0] kbd_dbg_ctrl1,
    input  [7:0] irq_dbg_imr, // the interrupt chain
    input  [7:0] irq_dbg_irr,
    input  [7:0] irq_dbg_isr,
    input  [7:0] inta_din,
    input  [7:0] cpu_irq_state,  // CPU: {IF, 5'b0, INTR, 1'b0}; the CPU exports no other interrupt state
    input  [7:0] inta_count,
    input  [15:0] artic_hi,        // U: the ARTIC counter's upper half, the value the firmware polls
    input  [7:0] io_itf_stage,
    // IO/DR/IV: the most recent I/O access, latched by pc9821_iobus so a freeze loop's polled
    // port is in the capture.
    input  [15:0] last_io_addr,
    input  [ 7:0] last_io_data,
    input         last_io_rd,
    input         last_io_wr,
    output reg [7:0] ch
);

    /* verilator lint_off WIDTHEXPAND */   // a 4-bit nibble is zero-extended to add an ASCII base; the sum IS the character
    function [7:0] wdg_hc(input [3:0] n);
        wdg_hc = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n);
    endfunction
    /* verilator lint_on WIDTHEXPAND */

    // THE RECORD'S FIELDS ARE ONE INSTANT (see the header): `snap` latches every diagnostic
    // field once, at the report's accept, and the nib selector below reads the held copies - one
    // instant for every field's digits however long the paced emission waits. A record is only
    // read after its snap (pc9821_dbg_record starts emitting the cycle after the trigger's
    // `start`, which IS the snap), so the copies need no reset; the benches snap first too.
    reg [15:0] cpu_cs_q, gdc_dbg_sad_q, artic_hi_q, last_io_addr_q;
    reg [31:0] cpu_eip_q, hdd_capacity_q, hdd_hps_cycles_q, ata_dbg_cmd_q;
    reg  [7:0] io_debug_status_q, vid_frame_cnt_q, hdd_req_cnt_q, hdd_err_cnt_q,
               vid_lit_cnt_q, ata_dbg_state_q, gdc_dbg_pitch_q, kbd_dbg_events_q,
               kbd_dbg_delivered_q, kbd_dbg_rd_data_q, kbd_dbg_wr_ctrl_q,
               kbd_dbg_last_del_q, kbd_dbg_ctrl0_q, kbd_dbg_ctrl1_q, irq_dbg_imr_q,
               irq_dbg_irr_q, irq_dbg_isr_q, inta_din_q, cpu_irq_state_q, inta_count_q,
               io_itf_stage_q, last_io_data_q;
    reg  [7:0]  fdc_dbg_state_q, fdc_dbg_cmd_q;
    reg [31:0]  fdc_dbg_result_q, fdc_dbg_chrn_q, ata_dbg_lba_q;
    reg [15:0]  ata_dbg_sec_q;
    reg  [3:0] io_dbg_gate_q;
    reg        triple_fault_reset_q, hdd_mounted_q, gdc_disp_q, hdd_busy_q, vid_lit_seen_q,
               mounted_at_run_q, gdc_dbg_col40_q, gdc_dbg_disp_q, kbd_dbg_rts_q,
               kbd_dbg_rx_en_q, kbd_irq_q, last_io_rd_q, last_io_wr_q;
    always @(posedge clk) begin
        if (snap) begin
            cpu_cs_q <= cpu_cs;               cpu_eip_q <= cpu_eip;
            io_debug_status_q <= io_debug_status; triple_fault_reset_q <= triple_fault_reset;
            hdd_mounted_q <= hdd_mounted;     hdd_capacity_q <= hdd_capacity;
            gdc_disp_q <= gdc_disp;           vid_frame_cnt_q <= vid_frame_cnt;
            hdd_req_cnt_q <= hdd_req_cnt;     hdd_err_cnt_q <= hdd_err_cnt;
            hdd_busy_q <= hdd_busy;           hdd_hps_cycles_q <= hdd_hps_cycles;
            vid_lit_seen_q <= vid_lit_seen;   vid_lit_cnt_q <= vid_lit_cnt;
            ata_dbg_state_q <= ata_dbg_state; ata_dbg_cmd_q <= ata_dbg_cmd;
            io_dbg_gate_q <= io_dbg_gate;     mounted_at_run_q <= mounted_at_run;
            gdc_dbg_sad_q <= gdc_dbg_sad;     gdc_dbg_pitch_q <= gdc_dbg_pitch;
            gdc_dbg_col40_q <= gdc_dbg_col40; gdc_dbg_disp_q <= gdc_dbg_disp;
            kbd_dbg_events_q <= kbd_dbg_events; kbd_dbg_delivered_q <= kbd_dbg_delivered;
            kbd_dbg_rd_data_q <= kbd_dbg_rd_data; kbd_dbg_wr_ctrl_q <= kbd_dbg_wr_ctrl;
            kbd_dbg_rts_q <= kbd_dbg_rts;     kbd_dbg_rx_en_q <= kbd_dbg_rx_en;
            kbd_irq_q <= kbd_irq;             kbd_dbg_last_del_q <= kbd_dbg_last_del;
            kbd_dbg_ctrl0_q <= kbd_dbg_ctrl0; kbd_dbg_ctrl1_q <= kbd_dbg_ctrl1;
            irq_dbg_imr_q <= irq_dbg_imr;     irq_dbg_irr_q <= irq_dbg_irr;
            irq_dbg_isr_q <= irq_dbg_isr;     inta_din_q <= inta_din;
            cpu_irq_state_q <= cpu_irq_state; inta_count_q <= inta_count;
            artic_hi_q <= artic_hi;           io_itf_stage_q <= io_itf_stage;
            last_io_addr_q <= last_io_addr;   last_io_data_q <= last_io_data;
            last_io_rd_q <= last_io_rd;       last_io_wr_q <= last_io_wr;
            fdc_dbg_state_q <= fdc_dbg_state; fdc_dbg_cmd_q <= fdc_dbg_cmd;
            fdc_dbg_result_q <= fdc_dbg_result; fdc_dbg_chrn_q <= fdc_dbg_chrn;
            ata_dbg_lba_q <= ata_dbg_lba;     ata_dbg_sec_q <= ata_dbg_sec;
        end
    end

    // The message, byte for byte, in one literal run: the table is generated from the layout
    // tools/decode_telemetry.py is written against, so a moved field shows as a decoder mismatch
    // rather than as a silently shifted capture. A field byte is 8'h00 here (the nib selector below
    // fills it); no literal byte is 0x00, so the marker is unambiguous. 512 deep, not 351: the index
    // is 9 bits (`msg[idx[8:0]]`), so Quartus derives a 512-word memory and reports that the
    // 351-word image does not match it; the table is declared as the index space it is addressed
    // with, and entries above 350 are never read (idx is 0..350 by contract -
    // pc9821_dbg_record.sv's WDG_MSG_LAST is 350 and the read is guarded).
    // THE TABLE IS LUTs BECAUSE THE READ IS ASYNCHRONOUS - measured, not assumed. Quartus names
    // the cause itself (Info 276007, "uninferred due to asynchronous read logic") and no
    // ramstyle changes it (three shapes were priced).
    reg [7:0] msg [0:511];
    initial begin
        msg[  0] = "W";  msg[  1] = " ";  msg[  2] = "C";  msg[  3] = "S";
        msg[  4] = "=";  msg[  5] = 8'h00;  msg[  6] = 8'h00;  msg[  7] = 8'h00;
        msg[  8] = 8'h00;  msg[  9] = " ";  msg[ 10] = "E";  msg[ 11] = "I";
        msg[ 12] = "P";  msg[ 13] = "=";  msg[ 14] = 8'h00;  msg[ 15] = 8'h00;
        msg[ 16] = 8'h00;  msg[ 17] = 8'h00;  msg[ 18] = 8'h00;  msg[ 19] = 8'h00;
        msg[ 20] = 8'h00;  msg[ 21] = 8'h00;  msg[ 22] = " ";  msg[ 23] = "S";
        msg[ 24] = "T";  msg[ 25] = "=";  msg[ 26] = 8'h00;  msg[ 27] = 8'h00;
        msg[ 28] = " ";  msg[ 29] = "T";  msg[ 30] = "F";  msg[ 31] = "=";
        msg[ 32] = 8'h00;  msg[ 33] = " ";  msg[ 34] = "D";  msg[ 35] = "=";
        msg[ 36] = 8'h00;  msg[ 37] = " ";  msg[ 38] = "C";  msg[ 39] = "=";
        msg[ 40] = 8'h00;  msg[ 41] = 8'h00;  msg[ 42] = 8'h00;  msg[ 43] = 8'h00;
        msg[ 44] = 8'h00;  msg[ 45] = 8'h00;  msg[ 46] = 8'h00;  msg[ 47] = 8'h00;
        msg[ 48] = " ";  msg[ 49] = "V";  msg[ 50] = "=";  msg[ 51] = 8'h00;
        msg[ 52] = " ";  msg[ 53] = "F";  msg[ 54] = "=";  msg[ 55] = 8'h00;
        msg[ 56] = 8'h00;  msg[ 57] = " ";  msg[ 58] = "R";  msg[ 59] = "=";
        msg[ 60] = 8'h00;  msg[ 61] = 8'h00;  msg[ 62] = " ";  msg[ 63] = "E";
        msg[ 64] = "=";  msg[ 65] = 8'h00;  msg[ 66] = 8'h00;  msg[ 67] = " ";
        msg[ 68] = "B";  msg[ 69] = "=";  msg[ 70] = 8'h00;  msg[ 71] = " ";
        msg[ 72] = "P";  msg[ 73] = "=";  msg[ 74] = 8'h00;  msg[ 75] = " ";
        msg[ 76] = "N";  msg[ 77] = "=";  msg[ 78] = 8'h00;  msg[ 79] = 8'h00;
        msg[ 80] = " ";  msg[ 81] = "A";  msg[ 82] = "=";  msg[ 83] = 8'h00;
        msg[ 84] = 8'h00;  msg[ 85] = " ";  msg[ 86] = "A";  msg[ 87] = "T";
        msg[ 88] = "A";  msg[ 89] = "=";  msg[ 90] = 8'h00;  msg[ 91] = 8'h00;
        msg[ 92] = 8'h00;  msg[ 93] = 8'h00;  msg[ 94] = 8'h00;  msg[ 95] = 8'h00;
        msg[ 96] = 8'h00;  msg[ 97] = 8'h00;  msg[ 98] = " ";  msg[ 99] = "G";
        msg[100] = "=";  msg[101] = 8'h00;  msg[102] = " ";  msg[103] = "M";
        msg[104] = "=";  msg[105] = 8'h00;  msg[106] = " ";  msg[107] = "S";
        msg[108] = "A";  msg[109] = "D";  msg[110] = "=";  msg[111] = 8'h00;
        msg[112] = 8'h00;  msg[113] = 8'h00;  msg[114] = 8'h00;  msg[115] = " ";
        msg[116] = "P";  msg[117] = "I";  msg[118] = "T";  msg[119] = "=";
        msg[120] = 8'h00;  msg[121] = 8'h00;  msg[122] = " ";  msg[123] = "C";
        msg[124] = "4";  msg[125] = "0";  msg[126] = "=";  msg[127] = 8'h00;
        msg[128] = " ";  msg[129] = "D";  msg[130] = "S";  msg[131] = "P";
        msg[132] = "=";  msg[133] = 8'h00;  msg[134] = " ";  msg[135] = "P";
        msg[136] = "S";  msg[137] = "2";  msg[138] = "=";  msg[139] = 8'h00;
        msg[140] = 8'h00;  msg[141] = " ";  msg[142] = "D";  msg[143] = "L";
        msg[144] = "V";  msg[145] = "=";  msg[146] = 8'h00;  msg[147] = 8'h00;
        msg[148] = " ";  msg[149] = "R";  msg[150] = "D";  msg[151] = "4";
        msg[152] = "1";  msg[153] = "=";  msg[154] = 8'h00;  msg[155] = 8'h00;
        msg[156] = " ";  msg[157] = "W";  msg[158] = "R";  msg[159] = "4";
        msg[160] = "3";  msg[161] = "=";  msg[162] = 8'h00;  msg[163] = 8'h00;
        msg[164] = " ";  msg[165] = "R";  msg[166] = "T";  msg[167] = "S";
        msg[168] = "=";  msg[169] = 8'h00;  msg[170] = " ";  msg[171] = "R";
        msg[172] = "X";  msg[173] = "E";  msg[174] = "=";  msg[175] = 8'h00;
        msg[176] = " ";  msg[177] = "I";  msg[178] = "R";  msg[179] = "Q";
        msg[180] = "=";  msg[181] = 8'h00;  msg[182] = " ";  msg[183] = "L";
        msg[184] = "S";  msg[185] = "C";  msg[186] = "=";  msg[187] = 8'h00;
        msg[188] = 8'h00;  msg[189] = " ";  msg[190] = "C";  msg[191] = "0";
        msg[192] = "=";  msg[193] = 8'h00;  msg[194] = 8'h00;  msg[195] = " ";
        msg[196] = "C";  msg[197] = "1";  msg[198] = "=";  msg[199] = 8'h00;
        msg[200] = 8'h00;  msg[201] = " ";  msg[202] = "I";  msg[203] = "M";
        msg[204] = "R";  msg[205] = "=";  msg[206] = 8'h00;  msg[207] = 8'h00;
        msg[208] = " ";  msg[209] = "I";  msg[210] = "R";  msg[211] = "R";
        msg[212] = "=";  msg[213] = 8'h00;  msg[214] = 8'h00;  msg[215] = " ";
        msg[216] = "I";  msg[217] = "S";  msg[218] = "R";  msg[219] = "=";
        msg[220] = 8'h00;  msg[221] = 8'h00;  msg[222] = " ";  msg[223] = "V";
        msg[224] = "E";  msg[225] = "C";  msg[226] = "=";  msg[227] = 8'h00;
        msg[228] = 8'h00;  msg[229] = " ";  msg[230] = "C";  msg[231] = "P";
        msg[232] = "U";  msg[233] = "=";  msg[234] = 8'h00;  msg[235] = 8'h00;
        msg[236] = " ";  msg[237] = "I";  msg[238] = "N";  msg[239] = "T";
        msg[240] = "A";  msg[241] = "=";  msg[242] = 8'h00;  msg[243] = 8'h00;
        msg[244] = " ";  msg[245] = "U";  msg[246] = "=";  msg[247] = 8'h00;
        msg[248] = 8'h00;  msg[249] = 8'h00;  msg[250] = 8'h00;  msg[251] = " ";
        msg[252] = "I";  msg[253] = "O";  msg[254] = "=";  msg[255] = 8'h00;
        msg[256] = 8'h00;  msg[257] = 8'h00;  msg[258] = 8'h00;  msg[259] = " ";
        msg[260] = "D";  msg[261] = "R";  msg[262] = "=";  msg[263] = 8'h00;
        msg[264] = " ";  msg[265] = "I";  msg[266] = "V";  msg[267] = "=";
        msg[268] = 8'h00;  msg[269] = 8'h00;  msg[270] = " ";  msg[271] = "H";
        msg[272] = "P";  msg[273] = "=";  msg[274] = 8'h00;  msg[275] = 8'h00;
        msg[276] = 8'h00;  msg[277] = 8'h00;  msg[278] = 8'h00;  msg[279] = 8'h00;
        msg[280] = 8'h00;  msg[281] = 8'h00;  msg[282] = " ";  msg[283] = "F";
        msg[284] = "S";  msg[285] = "T";  msg[286] = "=";  msg[287] = 8'h00;
        msg[288] = 8'h00;  msg[289] = " ";  msg[290] = "F";  msg[291] = "C";
        msg[292] = "M";  msg[293] = "=";  msg[294] = 8'h00;  msg[295] = 8'h00;
        msg[296] = " ";  msg[297] = "F";  msg[298] = "R";  msg[299] = "S";
        msg[300] = "=";  msg[301] = 8'h00;  msg[302] = 8'h00;  msg[303] = 8'h00;
        msg[304] = 8'h00;  msg[305] = 8'h00;  msg[306] = 8'h00;  msg[307] = 8'h00;
        msg[308] = 8'h00;  msg[309] = " ";  msg[310] = "F";  msg[311] = "C";
        msg[312] = "H";  msg[313] = "=";  msg[314] = 8'h00;  msg[315] = 8'h00;
        msg[316] = 8'h00;  msg[317] = 8'h00;  msg[318] = 8'h00;  msg[319] = 8'h00;
        msg[320] = 8'h00;  msg[321] = 8'h00;  msg[322] = " ";  msg[323] = "A";
        msg[324] = "L";  msg[325] = "B";  msg[326] = "=";  msg[327] = 8'h00;
        msg[328] = 8'h00;  msg[329] = 8'h00;  msg[330] = 8'h00;  msg[331] = 8'h00;
        msg[332] = 8'h00;  msg[333] = 8'h00;  msg[334] = 8'h00;  msg[335] = " ";
        msg[336] = "A";  msg[337] = "S";  msg[338] = "E";  msg[339] = "=";
        msg[340] = 8'h00;  msg[341] = 8'h00;  msg[342] = 8'h00;  msg[343] = 8'h00;
        msg[344] = " ";  msg[345] = "T";  msg[346] = "=";  msg[347] = 8'h00;
        msg[348] = 8'h00;  msg[349] = "?";  msg[350] = 8'h0A;
    end

    // An indexed read of the ROM, and a default arm (8'h00) for an index
    // outside the message (the watchdog never produces one; the bench checks
    // that it answers NUL).
    reg [7:0] lit;
    always @* begin
        if (idx > 16'd350) lit = 8'h00;
        else               lit = msg[idx[8:0]];
    end

    // The selector and the ONE decoder. The 137 field bytes are, without exception, wdg_hc() of one
    // nibble: a hex digit of a field, or a one-bit flag as the nibble {3'b000, flag} (rendered
    // "0"/"1"). So this case picks the nibble each index formats and wdg_hc below -- called once --
    // decodes it, so the byte map needs no per-byte wdg_hc() copies. An index
    // absent here is literal (`lit` answers) or past the message. Index 349 is the trigger, the ROM
    // '?' at msg[349] that pc9821_dbg_record.sv substitutes the report path byte into (the
    // WDG_TRIG_IDX compare in its byte mux), not a field of this formatter's.
    reg [3:0] nib;
    always @* begin
        case (idx)
            16'd5: nib = cpu_cs_q[15:12];
            16'd6: nib = cpu_cs_q[11:8];
            16'd7: nib = cpu_cs_q[7:4];
            16'd8: nib = cpu_cs_q[3:0];
            16'd14: nib = cpu_eip_q[31:28];
            16'd15: nib = cpu_eip_q[27:24];
            16'd16: nib = cpu_eip_q[23:20];
            16'd17: nib = cpu_eip_q[19:16];
            16'd18: nib = cpu_eip_q[15:12];
            16'd19: nib = cpu_eip_q[11:8];
            16'd20: nib = cpu_eip_q[7:4];
            16'd21: nib = cpu_eip_q[3:0];
            16'd26: nib = io_debug_status_q[7:4];
            16'd27: nib = io_debug_status_q[3:0];
            16'd32: nib = {3'b000, triple_fault_reset_q};
            16'd36: nib = {3'b000, hdd_mounted_q};
            16'd40: nib = hdd_capacity_q[31:28];
            16'd41: nib = hdd_capacity_q[27:24];
            16'd42: nib = hdd_capacity_q[23:20];
            16'd43: nib = hdd_capacity_q[19:16];
            16'd44: nib = hdd_capacity_q[15:12];
            16'd45: nib = hdd_capacity_q[11:8];
            16'd46: nib = hdd_capacity_q[7:4];
            16'd47: nib = hdd_capacity_q[3:0];
            16'd51: nib = {3'b000, gdc_disp_q};
            16'd55: nib = vid_frame_cnt_q[7:4];
            16'd56: nib = vid_frame_cnt_q[3:0];
            16'd60: nib = hdd_req_cnt_q[7:4];
            16'd61: nib = hdd_req_cnt_q[3:0];
            16'd65: nib = hdd_err_cnt_q[7:4];
            16'd66: nib = hdd_err_cnt_q[3:0];
            16'd70: nib = {3'b000, hdd_busy_q};
            16'd74: nib = {3'b000, vid_lit_seen_q};
            16'd78: nib = vid_lit_cnt_q[7:4];
            16'd79: nib = vid_lit_cnt_q[3:0];
            16'd83: nib = ata_dbg_state_q[7:4];
            16'd84: nib = ata_dbg_state_q[3:0];
            16'd90: nib = ata_dbg_cmd_q[31:28];
            16'd91: nib = ata_dbg_cmd_q[27:24];
            16'd92: nib = ata_dbg_cmd_q[23:20];
            16'd93: nib = ata_dbg_cmd_q[19:16];
            16'd94: nib = ata_dbg_cmd_q[15:12];
            16'd95: nib = ata_dbg_cmd_q[11:8];
            16'd96: nib = ata_dbg_cmd_q[7:4];
            16'd97: nib = ata_dbg_cmd_q[3:0];
            16'd101: nib = io_dbg_gate_q[3:0];
            16'd105: nib = {3'b000, mounted_at_run_q};
            16'd111: nib = gdc_dbg_sad_q[15:12];
            16'd112: nib = gdc_dbg_sad_q[11:8];
            16'd113: nib = gdc_dbg_sad_q[7:4];
            16'd114: nib = gdc_dbg_sad_q[3:0];
            16'd120: nib = gdc_dbg_pitch_q[7:4];
            16'd121: nib = gdc_dbg_pitch_q[3:0];
            16'd127: nib = {3'b000, gdc_dbg_col40_q};
            16'd133: nib = {3'b000, gdc_dbg_disp_q};
            16'd139: nib = kbd_dbg_events_q[7:4];
            16'd140: nib = kbd_dbg_events_q[3:0];
            16'd146: nib = kbd_dbg_delivered_q[7:4];
            16'd147: nib = kbd_dbg_delivered_q[3:0];
            16'd154: nib = kbd_dbg_rd_data_q[7:4];
            16'd155: nib = kbd_dbg_rd_data_q[3:0];
            16'd162: nib = kbd_dbg_wr_ctrl_q[7:4];
            16'd163: nib = kbd_dbg_wr_ctrl_q[3:0];
            16'd169: nib = {3'b000, kbd_dbg_rts_q};
            16'd175: nib = {3'b000, kbd_dbg_rx_en_q};
            16'd181: nib = {3'b000, kbd_irq_q};
            16'd187: nib = kbd_dbg_last_del_q[7:4];
            16'd188: nib = kbd_dbg_last_del_q[3:0];
            16'd193: nib = kbd_dbg_ctrl0_q[7:4];
            16'd194: nib = kbd_dbg_ctrl0_q[3:0];
            16'd199: nib = kbd_dbg_ctrl1_q[7:4];
            16'd200: nib = kbd_dbg_ctrl1_q[3:0];
            16'd206: nib = irq_dbg_imr_q[7:4];
            16'd207: nib = irq_dbg_imr_q[3:0];
            16'd213: nib = irq_dbg_irr_q[7:4];
            16'd214: nib = irq_dbg_irr_q[3:0];
            16'd220: nib = irq_dbg_isr_q[7:4];
            16'd221: nib = irq_dbg_isr_q[3:0];
            16'd227: nib = inta_din_q[7:4];
            16'd228: nib = inta_din_q[3:0];
            16'd234: nib = cpu_irq_state_q[7:4];
            16'd235: nib = cpu_irq_state_q[3:0];
            16'd242: nib = inta_count_q[7:4];
            16'd243: nib = inta_count_q[3:0];
            16'd247: nib = artic_hi_q[15:12];
            16'd248: nib = artic_hi_q[11:8];
            16'd249: nib = artic_hi_q[7:4];
            16'd250: nib = artic_hi_q[3:0];
            16'd255: nib = last_io_addr_q[15:12];
            16'd256: nib = last_io_addr_q[11:8];
            16'd257: nib = last_io_addr_q[7:4];
            16'd258: nib = last_io_addr_q[3:0];
            16'd263: nib = last_io_wr_q ? 4'h2 : {3'b0, last_io_rd_q};
            16'd268: nib = last_io_data_q[7:4];
            16'd269: nib = last_io_data_q[3:0];
            16'd274: nib = hdd_hps_cycles_q[31:28];
            16'd275: nib = hdd_hps_cycles_q[27:24];
            16'd276: nib = hdd_hps_cycles_q[23:20];
            16'd277: nib = hdd_hps_cycles_q[19:16];
            16'd278: nib = hdd_hps_cycles_q[15:12];
            16'd279: nib = hdd_hps_cycles_q[11:8];
            16'd280: nib = hdd_hps_cycles_q[7:4];
            16'd281: nib = hdd_hps_cycles_q[3:0];
            16'd287: nib = fdc_dbg_state_q[7:4];
            16'd288: nib = fdc_dbg_state_q[3:0];
            16'd294: nib = fdc_dbg_cmd_q[7:4];
            16'd295: nib = fdc_dbg_cmd_q[3:0];
            16'd301: nib = fdc_dbg_result_q[31:28];
            16'd302: nib = fdc_dbg_result_q[27:24];
            16'd303: nib = fdc_dbg_result_q[23:20];
            16'd304: nib = fdc_dbg_result_q[19:16];
            16'd305: nib = fdc_dbg_result_q[15:12];
            16'd306: nib = fdc_dbg_result_q[11:8];
            16'd307: nib = fdc_dbg_result_q[7:4];
            16'd308: nib = fdc_dbg_result_q[3:0];
            16'd314: nib = fdc_dbg_chrn_q[31:28];
            16'd315: nib = fdc_dbg_chrn_q[27:24];
            16'd316: nib = fdc_dbg_chrn_q[23:20];
            16'd317: nib = fdc_dbg_chrn_q[19:16];
            16'd318: nib = fdc_dbg_chrn_q[15:12];
            16'd319: nib = fdc_dbg_chrn_q[11:8];
            16'd320: nib = fdc_dbg_chrn_q[7:4];
            16'd321: nib = fdc_dbg_chrn_q[3:0];
            16'd327: nib = ata_dbg_lba_q[31:28];
            16'd328: nib = ata_dbg_lba_q[27:24];
            16'd329: nib = ata_dbg_lba_q[23:20];
            16'd330: nib = ata_dbg_lba_q[19:16];
            16'd331: nib = ata_dbg_lba_q[15:12];
            16'd332: nib = ata_dbg_lba_q[11:8];
            16'd333: nib = ata_dbg_lba_q[7:4];
            16'd334: nib = ata_dbg_lba_q[3:0];
            16'd340: nib = ata_dbg_sec_q[15:12];
            16'd341: nib = ata_dbg_sec_q[11:8];
            16'd342: nib = ata_dbg_sec_q[7:4];
            16'd343: nib = ata_dbg_sec_q[3:0];
            16'd347: nib = io_itf_stage_q[7:4];
            16'd348: nib = io_itf_stage_q[3:0];
            default: nib = 4'h0;
        endcase
    end

    always @* begin
        if (idx > 16'd350)     ch = 8'h00;   // past the message: NUL, the arm this case replaced
        else if (lit != 8'h00) ch = lit;     // a literal byte (a field byte is 0x00 in the ROM)
        else                   ch = wdg_hc(nib);
    end

endmodule

`default_nettype wire
