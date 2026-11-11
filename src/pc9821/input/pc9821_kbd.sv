// PC-98 keyboard controller - PC-9821 MiSTer core.
//
// Mainboard interface: uPD8251A at 0x41 (data) / 0x43 (control/status).
// NP2kai io/serial.c is the primary 8251/status/command-flow reference.
// MiSTer hps_io emits PS/2 Set-2 event bytes in ps2_key[7:0], with bit 8
// marking E0 extension, bit 9 pressed, and bit 10 toggled per event.
// Translation follows the physical Set-1-to-PC-98 correspondence in
// qemu-pc98 pc98-kbd.c, converted here to direct MiSTer Set-2 decoding.

`default_nettype none

module pc9821_kbd #(
    parameter integer SYS_CLOCK_HZ = 50_000_000,
    // Typematic auto-repeat, NP2kai keystat.c defaults (500 ms delay, 50 ms interval).
    // 26 bits: REPEAT_DELAY is SYS_CLOCK_HZ/2, which is 60_000_000 at 120 MHz and so
    // still inside 2^26 (67_108_864); a profile past 134 MHz would need widening.
    parameter [25:0] REPEAT_DELAY    = 26'(SYS_CLOCK_HZ / 2),
    parameter [25:0] REPEAT_INTERVAL = 26'(SYS_CLOCK_HZ / 20),
    // The RE-POKE tick: how often an unread delivered byte re-strokes the IRQ
    // request. NP2kai pokes pic_setirq(1) at EVERY keyboard transfer tick while
    // the receive side is not empty (io/serial.c keyboard_callback), with
    // keybrd.xferclock = pccore.realclock / 1920 (keyboard_changeclock) - one
    // byte-time per 1920 base-clock cycles. pccore.realclock is the base clock
    // at multiple 1 (pccore.h PCBASECLOCK25 = 2,457,600), so the transfer rate
    // is 2,457,600 / 1920 = 1,280 byte-times per second. That is the DEVICE's
    // rate - clk_sys only scales the count (the rate rule), and a bench
    // overrides this parameter to make the window observable.
    parameter [25:0] XFER_TICK_CYCLES = 26'(SYS_CLOCK_HZ / 1280)
) (
    input wire clk,
    input wire rst_n,

    input  wire       cs,
    input  wire       a0,   // 0=data, 1=control/status
    input  wire       wr,
    input  wire       rd,
    input  wire [7:0] din,
    output wire [7:0] dout,

    output wire irq,
    input wire [10:0] ps2_key,
    input wire        layout_jis,   // OSD "Keyboard": 1 = JIS host layout, 0 = US (translate())
    output wire [2:0] led_status,   // MiSTer hps_io order {scrolllock, numlock, capslock}

    // Bring-up telemetry: enough to tell "the MiSTer never gave us a key" from
    // "we never handed it to the guest" from "the guest never asked".
    output reg  [7:0] dbg_events,
    output reg  [7:0] dbg_delivered,
    output reg  [7:0] dbg_rd_data,
    output reg  [7:0] dbg_wr_ctrl,
    output wire       dbg_rts,
    output wire       dbg_rx_en,
    output reg  [7:0] dbg_last_del,    // last byte handed to the guest
    output reg  [7:0] dbg_ctrl0,       // 8251 mode byte (first control write)
    output reg  [7:0] dbg_ctrl1        // 8251 command byte (second control write)
);

  localparam [7:0] KST_RXRDY = 8'h02;
  localparam [7:0] KST_PARITY = 8'h08;
  localparam [7:0] KST_OVERRUN = 8'h10;
  localparam [7:0] KST_FRAMING = 8'h20;

  localparam [3:0] LOCK_NUM = 4'h1;
  localparam [3:0] LOCK_CAPS = 4'h4;
  localparam [3:0] LOCK_KANA = 4'h8;

  // Direct PS/2 Set-2 -> NEC PC-98 physical-key translation, for the two host layouts.
  //
  // THE SOURCE. Main_MiSTer's input.cpp ev2ps2[] turns each Linux key code into the PS/2 set-2
  // code that reaches ps2_key here; this table turns that code into the PC-98 key number (NP2kai
  // keystat.tbl names each one). Every key is mapped BY POSITION, as NP2kai sdl/kbtrans.c
  // sdlcnv106 maps a JIS 106-key host and qemu-pc98 hw/input/pc98-kbd.c at_set1_to_pc98 maps a
  // set-1 one, so a key gives the PC-98 key at the same place on the PC-98 keyboard and Shift
  // gives what the PC-98 prints on that key's upper half (the BIOS table, BANK7@0x632B).
  //
  // THE LAYOUT (OSD "Keyboard", `jis`). The two layouts differ in exactly the four set-2 codes
  // REMAP_SLOT() below names, each a JIS key whose US cap carries a different symbol:
  //   set-2  JIS cap       JIS layout gives   US cap   US layout gives
  //   0x0E   hankaku/zen   nothing            ` ~      @ ~   (0x1A)
  //   0x54   @ `           @ ~   (0x1A)       [ {      [ {   (0x1B)
  //   0x5B   [ {           [ {   (0x1B)       ] }      ] }   (0x28)
  //   0x5D   ] }           ] }   (0x28)       \ |      \ |   (0x0D, the BIOS's 0x5C)
  // JIS is NP2kai sdlcnv106 (SDL_SCANCODE_BACKSLASH -> 0x28, LEFTBRACKET -> 0x1a, RIGHTBRACKET
  // -> 0x1b; it has no GRAVE row). US gives the US caps' symbols for the three bracket/backslash
  // keys, unshifted and shifted, which is NP2 windows/winkbd.cpp key106[] on a US host (indexed
  // by the US virtual key: 0xDB `[` -> 0x1b, 0xDD `]` -> 0x28, 0xDC `\` -> 0x0d, 0xC0 `` ` `` ->
  // 0x1a) and NP2kai wx/kbtrans.cpp ascii_to_pc98_106 (`[` 0x1b, `\` 0x0d, `]` 0x28). The PC-98
  // has no ` key, so the US ` key gives @ (Shift: ~), the US caps' only other missing symbol.
  // A DISAGREEMENT IN THE PRIMARY REFERENCE: NP2kai's SDL table for a 101-key host,
  // sdl/kbtrans.c sdlcnv101, maps these keys BY POSITION (GRAVE -> 0x0d, LEFTBRACKET -> 0x1a,
  // RIGHTBRACKET -> 0x1b, BACKSLASH -> 0x28: this table's JIS row plus ` -> yen), while the same
  // file's libretro table lrcnv101 (RETROK_LEFTBRACKET -> 0x1b, RIGHTBRACKET -> 0x28,
  // BACKSLASH -> 0x0d) and winkbd key106[] give the US caps' symbols. The US layout follows the
  // symbol tables, because a user who selects US asks for the symbols the caps show; the
  // positional mapping is what the JIS layout already gives.
  // Every other key is positional in both layouts: the US caps whose symbol differs keep the
  // PC-98 key at their position (= gives ^, ' gives :, and the shifted digits are the PC-98's),
  // because giving the US symbol would need a Shift the user is not holding, or a held Shift
  // removed, and a game reading the key matrix would see that.
  function automatic [7:0] translate(input jis, input extended, input [7:0] set2);
    begin
      if (extended) begin
        case (set2)
          8'h11:   translate = 8'h35;  // right Alt -> XFER (NP2kai kbtrans.c)
          8'h14:   translate = 8'h73;  // right Ctrl -> GRPH (NP2kai kbtrans.c)
          8'h1F:   translate = 8'h77;  // left Win
          8'h27:   translate = 8'h78;  // right Win
          // Menu -> KANA 0x72, deliberately NOT NP2kai's APP 0x79: a US keyboard has no
          // katakana/hiragana key, and Menu is the least-used free Windows-cluster key. The
          // JIS katakana/hiragana key (set-2 0x13 below) gives KANA too.
          8'h2F:   translate = 8'h72;  // Menu -> KANA
          8'h4A:   translate = 8'h41;  // keypad /
          8'h5A:   translate = 8'h1C;  // keypad Enter
          8'h69:   translate = 8'h3F;  // End -> HELP
          8'h6B:   translate = 8'h3B;  // Left
          8'h6C:   translate = 8'h3E;  // Home -> HOME/CLR
          8'h70:   translate = 8'h38;  // Insert
          8'h71:   translate = 8'h39;  // Delete
          8'h72:   translate = 8'h3D;  // Down
          8'h74:   translate = 8'h3C;  // Right
          8'h75:   translate = 8'h3A;  // Up
          8'h77:   translate = 8'h60;  // Pause -> STOP (hps_io normalized)
          8'h7A:   translate = 8'h37;  // Page Down -> ROLL DOWN
          8'h7C:   translate = 8'h61;  // Print Screen -> COPY (hps_io normalized)
          8'h7D:   translate = 8'h36;  // Page Up -> ROLL UP
          default: translate = 8'hFF;
        endcase
      end else begin
        case (set2)
          8'h76: translate = 8'h00;  // Escape
          8'h16: translate = 8'h01;  // 1
          8'h1E: translate = 8'h02;  // 2
          8'h26: translate = 8'h03;  // 3
          8'h25: translate = 8'h04;  // 4
          8'h2E: translate = 8'h05;  // 5
          8'h36: translate = 8'h06;  // 6
          8'h3D: translate = 8'h07;  // 7
          8'h3E: translate = 8'h08;  // 8
          8'h46: translate = 8'h09;  // 9
          8'h45: translate = 8'h0A;  // 0
          8'h4E: translate = 8'h0B;  // minus
          8'h55: translate = 8'h0C;  // caret (US =)
          8'h6A: translate = 8'h0D;  // JIS yen key (Main KEY_YEN) -> YEN
          8'h66: translate = 8'h0E;  // Backspace
          8'h0D: translate = 8'h0F;  // Tab
          8'h15: translate = 8'h10;  // Q
          8'h1D: translate = 8'h11;  // W
          8'h24: translate = 8'h12;  // E
          8'h2D: translate = 8'h13;  // R
          8'h2C: translate = 8'h14;  // T
          8'h35: translate = 8'h15;  // Y
          8'h3C: translate = 8'h16;  // U
          8'h43: translate = 8'h17;  // I
          8'h44: translate = 8'h18;  // O
          8'h4D: translate = 8'h19;  // P
          // The four layout keys (see THE LAYOUT above).
          8'h0E: translate = jis ? 8'hFF : 8'h1A;  // JIS hankaku/zenkaku: nothing; US `: @
          8'h54: translate = jis ? 8'h1A : 8'h1B;  // JIS @: @; US [: [
          8'h5B: translate = jis ? 8'h1B : 8'h28;  // JIS [: [; US ]: ]
          8'h5D: translate = jis ? 8'h28 : 8'h0D;  // JIS ]: ]; US \: YEN (BIOS 0x5C '\')
          8'h5A: translate = 8'h1C;  // Enter
          8'h1C: translate = 8'h1D;  // A
          8'h1B: translate = 8'h1E;  // S
          8'h23: translate = 8'h1F;  // D
          8'h2B: translate = 8'h20;  // F
          8'h34: translate = 8'h21;  // G
          8'h33: translate = 8'h22;  // H
          8'h3B: translate = 8'h23;  // J
          8'h42: translate = 8'h24;  // K
          8'h4B: translate = 8'h25;  // L
          8'h4C: translate = 8'h26;  // semicolon
          8'h52: translate = 8'h27;  // colon (US ')
          8'h1A: translate = 8'h29;  // Z
          8'h22: translate = 8'h2A;  // X
          8'h21: translate = 8'h2B;  // C
          8'h2A: translate = 8'h2C;  // V
          8'h32: translate = 8'h2D;  // B
          8'h31: translate = 8'h2E;  // N
          8'h3A: translate = 8'h2F;  // M
          8'h41: translate = 8'h30;  // comma
          8'h49: translate = 8'h31;  // period
          8'h4A: translate = 8'h32;  // slash
          // RO (PC-98 0x33, Shift gives '_'): the JIS ro key (Main KEY_RO -> 0x51; NP2kai
          // sdlcnv106 INTERNATIONAL1 -> 0x33) and the ISO key left of Z (Main KEY_102ND -> 0x61;
          // NP2 winkbd.cpp key106[0xE2] VK_OEM_102 -> 0x33), the same place on both keyboards.
          8'h51: translate = 8'h33;  // JIS ro
          8'h61: translate = 8'h33;  // ISO 102nd key
          8'h29: translate = 8'h34;  // Space
          8'h14: translate = 8'h74;  // left Ctrl
          8'h11: translate = 8'h51;  // left Alt -> NFER (NP2kai kbtrans.c)
          8'h12, 8'h59: translate = 8'h70;  // both Shift keys -> NEC SHIFT. NP2kai's
          // default kbdtype folds RSHIFT 0x7D onto 0x70 (keystat.c keystat_down), and the
          // BIOS shift byte (0x53A bit 0) is written only for keys 0x70-0x74.
          8'h58: translate = 8'h71;  // Caps Lock
          // The JIS conversion keys (Main ev2ps2: KEY_MUHENKAN -> 0x67, KEY_HENKAN -> 0x64,
          // KEY_KATAKANA/HIRAGANA/KATAKANAHIRAGANA -> 0x13), as qemu-pc98 at_set1_to_pc98 maps
          // their set-1 0x7B/0x79 (0x51/0x35) and NP2kai x/gtk2/gtk_keyboard.c xkeyconv_misc
          // maps MUHE/HENK/HIRA/KATA (0x51/0x35/0x72). Left/right Alt keep NFER/XFER too, so a
          // US keyboard reaches them.
          8'h67: translate = 8'h51;  // muhenkan -> NFER
          8'h64: translate = 8'h35;  // henkan -> XFER
          8'h13: translate = 8'h72;  // katakana/hiragana -> KANA
          8'h05: translate = 8'h62;  // F1 -> NEC F1 (NP2kai lrcnv106 F1->0x62); HELP is End
                                     // (0x69 -> 0x3F above), so an F1->HELP remap would
                                     // make NEC F1 unreachable (M1)
          8'h06: translate = 8'h63;  // F2
          8'h04: translate = 8'h64;  // F3
          8'h0C: translate = 8'h65;  // F4
          8'h03: translate = 8'h66;  // F5
          8'h0B: translate = 8'h67;  // F6
          8'h83: translate = 8'h68;  // F7
          8'h0A: translate = 8'h69;  // F8
          8'h01: translate = 8'h6A;  // F9
          8'h09: translate = 8'h6B;  // F10
          // F11/F12 -> VF1/VF2, the PC-98's own keys right of f.10 (NP2kai keystat.tbl
          // 0x52 "VF1", 0x53 "VF2"; NP2kai wx/kbtrans.cpp labels WXK_F11 "VF1" and WXK_F12
          // "VF2"). Never STOP: F11 answering 0x60 made an ordinary F11 press read as the STOP
          // key (tb_pc9821_kbd_stop pins it). F12 is the MiSTer menu key (Main_MiSTer
          // user_io.cpp is_menu_event), so it reaches the core only when the framework's menu
          // is moved off it. VF3-VF5 (0x54-0x56) have no host key: Main_MiSTer sends nothing
          // for F13-F15 (ev2ps2 rows 183-185 are NONE).
          8'h78: translate = 8'h52;  // F11 -> VF1
          8'h07: translate = 8'h53;  // F12 -> VF2
          // NumLock/ScrollLock -> keypad = / keypad , - the two PC-98 keypad keys a PC keypad
          // lacks (NP2kai keystat.tbl 0x4d "[=]", 0x4f "[,]"); Main_MiSTer sends nothing for
          // KEY_KPEQUAL/KEY_KPCOMMA (ev2ps2 rows 117 and 121 are NONE), and NP2kai itself offers
          // both only on a spare host key (x/kbdmng.c kbdmng_f12keys). They reach the core
          // because hps_io's PS2WE makes Main_MiSTer pass them through (user_io.cpp
          // `ps2ctl_modifier`); Win+NumLock/ScrollLock still switch the framework's emulation.
          8'h77: translate = 8'h4D;  // NumLock -> keypad =
          8'h7E: translate = 8'h4F;  // ScrollLock -> keypad ,
          8'h7B: translate = 8'h40;  // keypad minus
          8'h7C: translate = 8'h45;  // keypad multiply
          8'h79: translate = 8'h49;  // keypad plus
          8'h6C: translate = 8'h42;  // keypad 7
          8'h75: translate = 8'h43;  // keypad 8
          8'h7D: translate = 8'h44;  // keypad 9
          8'h6B: translate = 8'h46;  // keypad 4
          8'h73: translate = 8'h47;  // keypad 5
          8'h74: translate = 8'h48;  // keypad 6
          8'h69: translate = 8'h4A;  // keypad 1
          8'h72: translate = 8'h4B;  // keypad 2
          8'h7A: translate = 8'h4C;  // keypad 3
          8'h70: translate = 8'h4E;  // keypad 0
          8'h71: translate = 8'h50;  // keypad period
          default: translate = 8'hFF;
        endcase
      end
    end
  endfunction

  // The set-2 codes whose translation depends on the layout, as {is one, slot}: the four rows
  // marked in translate() above. A key held across a layout change must break as the key it
  // made (see THE LAYOUT A HELD KEY MADE below), so each needs a slot of its own.
  // tools/gen_keymap_table.py --check holds this list equal to the rows that differ.
  function automatic [2:0] remap_slot(input extended, input [7:0] set2);
    begin
      if (extended) remap_slot = 3'b000;
      else case (set2)
        8'h0E:   remap_slot = 3'b100;
        8'h54:   remap_slot = 3'b101;
        8'h5B:   remap_slot = 3'b110;
        8'h5D:   remap_slot = 3'b111;
        default: remap_slot = 3'b000;
      endcase
    end
  endfunction

  // NP2kai keystat.tbl kbexflag KBEX_NONREP (keystat.tbl:146-230) marks 0x52-0x56
  // (vf.1-vf.5), 0x62-0x6B (F1-F10), 0x70-0x74 (SHIFT/CAPS/KANA/GRPH/CTRL), 0x78
  // (RWIN), 0x79 (APP) and 0x7D (right Shift). 0x7D has no PS/2 source here (right
  // Shift folds to 0x70); VF1/VF2 (F11/F12) are the reachable VF keys and the range keeps
  // the table's VF row whole. 0x77 (left Win) is REPEATABLE in that table - the row above
  // it ends at 0x74 and the 0x78 row is RWIN/APP - so a 0x77..0x79 range would make LWIN
  // stop repeating where the reference repeats it.
  function automatic nonrep(input [7:0] code);
    begin
      nonrep = ((code >= 8'h52) && (code <= 8'h56)) ||   // VF1-VF5
               ((code >= 8'h62) && (code <= 8'h6B)) ||   // F1-F10
               ((code >= 8'h70) && (code <= 8'h74)) ||   // SHIFT/CAPS/KANA/GRPH/CTRL
               (code == 8'h78) || (code == 8'h79);       // RWIN/APP
    end
  endfunction

  // Direct PS/2 Set-2 -> NEC PC-98 physical-key translation table, both layouts: address
  // {jis, extended, set2}, 1,024 entries in a ROM initialized from the translation function,
  // replacing the case on the active event path. The layout is an ADDRESS BIT, not a mux after
  // the read, so the event path's depth and timing are those of the one-layout table.
  // MEMORY TYPE: M10K. At 1024 x 8 = 8,192 bits the table fits one M10K exactly (1K x 8 mode),
  // and an MLAB cannot take it at all: the base fit's Fitter RAM Summary placed the earlier
  // `ramstyle = "MLAB"` request as AUTO in one M10K block, 0 MLABs, "MLAB: No - Address Too
  // Wide" (10 address bits; an MLAB is 32 or 64 deep). So the attribute names what the fitter
  // builds, and no LAB is spent on the table. tools/res_exp_map.py, this module alone, MLAB ->
  // M10K: ALMs needed 349 -> 348, combinational ALUTs 530 -> 530, registers 320 -> 320, block
  // memory bits 9,472 -> 9,472, MLAB memory bits 0 -> 0 (the read is registered either way).
  (* ramstyle = "M10K" *) reg [7:0] kbd_lut [0:1023];
  integer lut_i;
  initial begin
    for (lut_i = 0; lut_i < 1024; lut_i = lut_i + 1) begin
      kbd_lut[lut_i] = translate(lut_i[9], lut_i[8], lut_i[7:0]);
    end
  end
  // OR 0x85 (TXRDY, TXEMPTY, DSR).
  reg [7:0] status_reg;
  reg rts, rx_enabled, tx_enabled;
  reg [7:0] ctrl_writes;
  reg [7:0] rx_latch;
  // Whether the byte currently sitting unread in rx_latch was delivered by a
  // COMMAND RESPONSE (deliver_resp) rather than by the key FIFO. NP2kai's
  // keyboard_ctrl() clears its control queue (keybrd.ctrls = 0) whenever it queues
  // a leading FA/FC, so a new command response DISCARDS a pending, unread command
  // response; a key byte is not its queue and survives. This bit is what lets the
  // core tell the two apart when that clear is applied (see st_resp_clear below).
  reg       rx_is_resp;
  reg       cmd_bit3;   // bit 3 of the previous command write, for the reset edge

  // THE PRESENTATION PACE. On the real keyboard the next byte cannot be presented
  // until the NEXT keyboard transfer slot: NP2kai io/serial.c keyboard_callback moves
  // one byte per keybrd.xferclock tick, and keyboard_changeclock sets that tick from
  // pccore.realclock / 1920 (2,457,600 / 1920 = 1,280 byte-times/s, one byte per
  // 0.78 ms). Without it the model delivers the next FIFO byte one clk after the
  // guest's 0x41 read, so a guest that peeks 0x41 before chaining (a disk image's
  // HSB.EXE INT 09h hook, 0x2CE5/0x2C3D) sees the NEXT key instead of the stale data
  // register the machine returns, steals a make or break, and leaves a modifier
  // stuck. This is a TIMING-OF-PRESENTATION delay only: the FIFO keeps every byte, in
  // order, and the value/status semantics are untouched.
  //   pace_div = 0 means "the receive side has been idle for at least a tick", so the
  //   FIRST byte after idle is still presented immediately. A delivery loads it with
  //   XFER_TICK_CYCLES - 1, so the next delivery is exactly XFER_TICK_CYCLES later.
  //   It is a separate divider from xfer_div (the IRQ re-poke): the re-poke restarts
  //   on every delivery already, and a delivered-and-read byte leaves nothing for the
  //   re-poke to stroke; the two counters never share a terminal count.
  // Both transfer-tick dividers (pace_div here, xfer_div below) range over 0..XFER_TICK_CYCLES-1
  // (pace_div: reset 0, loaded with XFER-1, counts down to 0; xfer_div: reset 0, a delivery loads
  // 1, wraps at XFER-1), so each needs only the bits that range takes, not the parameter's 26.
  localparam integer XFER_W = (XFER_TICK_CYCLES > 26'd1) ? $clog2(XFER_TICK_CYCLES) : 1;
  localparam [XFER_W-1:0] XFER_ONE  = 1;
  localparam [25:0]       XFER_LAST26 = XFER_TICK_CYCLES - 26'd1;
  localparam [XFER_W-1:0] XFER_LAST = XFER_LAST26[XFER_W-1:0];
  reg [XFER_W-1:0] pace_div;
  wire       pace_ready = (pace_div == '0);

  // Key events and command responses are separate, matching NP2kai's control
  // response priority over normal keyboard traffic.
  reg [7:0] fifo[0:15];
  reg [3:0] fifo_head, fifo_tail;
  reg [4:0] fifo_cnt;
  reg [23:0] resp_shift;
  reg [1:0] resp_count;

  reg cmd_pending;
  reg [7:0] cmd_opcode;
  reg [3:0] lock_flags;
  // Keyboard command 0x9C's parameter: 0x70 is the protocol's "inhibit key
  // repeating" (docs: tmk_keyboard wiki PC-9801-Keyboard, "Inhibiting key
  // repeating 0x9C 0x70"; the Xe10's PC-9801-119 keyboard answers FA to both
  // bytes and supports it). Any other parameter re-enables repeating.
  // NP2kai keystat.c keystat_ctrlsend case 0x9c stores the parameter as
  // keyctrl.keyrep and keystat_down suppresses repeated makes when it is 0x70;
  // its own keyrepeat_proc ignores the value, which is the divergence fixed
  // here. The parameter's repeat TIMING is not modelled (NP2kai does not
  // model it either).
  reg repeat_inhibit;
  // MEMORY TYPE: M10K, NOT MLAB - measured, not a preference. An MLAB is built from a
  // LAB's own ALMs and LABs are this device's BINDING resource (the fit has 88 of 553 M10K
  // blocks free and 4,163 of 4,191 LABs used), so the MLAB form spends the scarce one.
  // tools/res_exp_map.py, this module alone, one variable (MLAB -> M10K): ALMs needed
  // 294 -> 266, combinational ALUTs 420 -> 408, registers 280 -> 272, MLAB memory bits
  // 1,024 -> 0, +1 M10K block. Same values and cycles: both forms are a registered read.
  (* ramstyle = "M10K" *) reg [7:0] key_state [0:127];   // {generation, down} per NEC key number
  // Typematic repeat: the last repeatable key held (8'hFF = none), whether its
  // break+make pair is still being pushed, and the delay/interval countdown.
  reg [7:0]  rep_key;
  reg [1:0]  rep_pend;
  reg [25:0] rep_timer;
  // PENDING breaks owed for normalized Pause taps (0..3). Each tap make enqueues
  // its own break on the next idle cycle, so two makes landing before the first
  // break enqueues owe TWO breaks; a single bit would drop the second break and
  // leave its make unbroken (a stuck STOP-down reaching the guest). The host sends
  // one token per press, milliseconds apart, so this never exceeds 1 in practice -
  // the width is a guard, not a model of reachable backpressure.
  reg [1:0]  tap_brk;
  // The RE-POKE divider (see the irq assign below): free-running, so the re-strokes
  // are phase-deterministic and the first one after a delivery is at most one
  // transfer tick away.
  // xfer_div is XFER_W bits (see pace_div's note).
  reg [XFER_W-1:0] xfer_div;
  integer k;
  // key_state's power-up state: stamp 0 under `key_epoch` 0 reads "not down" for every
  // entry. The RESET state is the epoch bump in the reset arms below.
  initial begin
    for (k = 0; k < 128; k = k + 1) key_state[k] = 8'b0;
  end
  /* verilator lint_off PROCASSINIT */   // the initialiser is the register's power-up value
  reg ps2_key_prev = 1'b0;
  reg rst_n_prev   = 1'b0;   // rst_n one clk ago: the module reset's leading edge, for the epoch bump
  /* verilator lint_on PROCASSINIT */

  // THE TRANSLATION ROM'S READ IS REGISTERED, AND ITS READ REGISTER CARRIES NO POWER-UP VALUE.
  // Both halves are load-bearing and only together. The synchronous read is what lets the ROM
  // be block RAM at all; a POWER-UP VALUE ON THE REGISTER THAT CAPTURES IT puts the whole
  // table back into combinational LUTs (measured on the earlier one-layout 512 x 8 = 4,096-bit
  // table: 225 combinational ALUTs, ~40 % of the module) - Quartus 17.0.2 reports that as
  //   Info (276007): RAM logic "kbd_lut" is uninferred due to asynchronous read logic,
  // which names the symptom and not the cause. Measured with tools/res_exp_map.py (one
  // `quartus_map` of this module, ~1 min): taking this one value off the read register is
  // what made the ROM row appear (512x8 then; 1024x8 with the layout bit); the `ramstyle` attribute (MLAB or M10K), the
  // initialised contents and the address cone change nothing. A reset cleanup (9dc1214c)
  // added `event_code = 8'hFF;` here for 4-state determinism and silently cost the ROM, and
  // nothing in this tree can see it - Verilator is 2-state and no bench reads an inference -
  // so DO NOT give `rom_q` a power-up value. The "no event can fire before the first read
  // lands" property that value was added for is kept by `rom_valid` instead, applied on the
  // wire below rather than as a register power-up value.
  // A block-RAM read returns one clk later, so the WHOLE event path moves with it: `ps2_key_q`
  // carries the two ps2_key bits this logic reads (the toggling event bit and the pressed bit)
  // one clk earlier, i.e. describing the SAME ps2_key value the ROM's registered output does,
  // so `event_code` and every signal that qualifies it are aligned. hps_io holds ps2_key until
  // the next event and events are milliseconds apart, so the one extra clk is not observable;
  // the keyboard is not on any hot path.
  reg [7:0]  rom_q;                // the ROM's read register: NO power-up value (see above)
  /* verilator lint_off PROCASSINIT */   // the initialisers are the registers' power-up values
  reg [1:0]  ps2_key_q = 2'b00;
  reg        rom_valid = 1'b0;     // 0 until the first ROM read has landed
  reg [3:0]  held     = 4'b0000;   // per remap slot: the host key is down
  reg [3:0]  held_jis = 4'b0000;   // per remap slot: the layout its make was translated in
  /* verilator lint_on PROCASSINIT */
  // ---- THE LAYOUT A HELD KEY MADE --------------------------------------------------------
  // A layout change while a layout key is down must not strand its make: the US `]` held
  // across a flip to JIS would make 0x28 and break 0x9B, a key the guest never saw go down
  // (the dedup swallows it) - and 0x28 would stay down in the guest. So each of the four
  // layout keys (remap_slot) records the layout its make was read in, and while it is held
  // its reads (the typematic re-makes and the break) use THAT layout, not the OSD's. Every
  // other key reads the same byte in both halves of the ROM, so the layout bit is moot there.
  // The record is the address bit itself (`lut_jis_q`, registered with the read), so it is
  // exactly the layout the delivered make came from, whatever the OSD did around it.
  // ONE WRITER: `held`/`held_jis` change only on a host event of a layout key (ps_event, one
  // per hps_io ps2_key toggle) and on the module reset, folded into one next-state below.
  // The record as it stands after this clk's event: an event of the same slot taken this clk
  // (ps_event below, one clk after its read) has not reached `held` yet, so its press/release
  // and layout are bypassed in - the read issued now sees the record that event leaves,
  // however close the two host events are.
  reg  [2:0] slot_q;               // remap_slot of the code the ROM read register holds
  reg        lut_jis_q;            // the layout bit that read used
  wire ps_event = (ps2_key_q[1] != ps2_key_prev);
  wire [2:0] key_slot  = remap_slot(ps2_key[8], ps2_key[7:0]);
  // A module reset clears the record on this edge, so it bypasses in as "not held".
  wire       rec_byp   = ps_event && (slot_q == key_slot);
  wire       rec_held  = rst_n && (rec_byp ? ps2_key_q[0] : held[key_slot[1:0]]);
  wire       rec_jis   = rec_byp ? lut_jis_q    : held_jis[key_slot[1:0]];
  wire       lut_jis   = (key_slot[2] && rec_held) ? rec_jis : layout_jis;
  always @(posedge clk) begin
    rom_q     <= kbd_lut[{lut_jis, ps2_key[8], ps2_key[7:0]}];
    rom_valid <= 1'b1;
    ps2_key_q <= ps2_key[10:9];
    slot_q    <= key_slot;
    lut_jis_q <= lut_jis;
  end
  // Unmapped until the first read lands. This is the register power-up value the read
  // register must not carry, expressed as a one-clk guard instead.
  wire [7:0] event_code = rom_valid ? rom_q : 8'hFF;
  // The held-layout record's one next-state: the module reset clears it (the dedup's epoch
  // bump forgets every held key at the same reset); a layout key's host event records press
  // or release, and a press records the layout its read used. The event is taken whether or
  // not the code is mapped in that layout (the JIS half/full-width key maps to nothing), so
  // its release is read in the layout it was pressed in either way.
  always @(posedge clk) begin
    if (!rst_n) begin
      held     <= 4'b0000;
      held_jis <= 4'b0000;
    end else if (ps_event && slot_q[2]) begin
      held[slot_q[1:0]] <= ps2_key_q[0];                     // ps2_key bit 9: pressed
      if (ps2_key_q[0]) held_jis[slot_q[1:0]] <= lut_jis_q;
    end
  end
  wire event_mapped = (event_code != 8'hFF);
  wire event_lock = (event_code == 8'h71) || (event_code == 8'h72);
  wire event_pressed = ps2_key_q[0];

  // ---- THE DEDUP TABLE'S READ IS CLOCKED, SO THE WHOLE DECISION MOVES ONE clk DEEPER --
  // `key_down[0:127]` (the M2 mechanical-lock fix) lives in `key_state`, a block memory,
  // and a block-RAM read returns one clk later - so the comparison "is this key already
  // down", and every signal derived from it, cannot happen in the clk the event code
  // arrives in. The event is carried one stage: `event_code`/`event_lock`/`event_pressed`
  // /`ps_event && event_mapped` are registered here as `ev2_*`, and the decision below is
  // taken from those plus the table's registered read. `ev2_valid` is
  // `ps_event && event_mapped` one clk later.
  //
  // THAT ONE clk IS THE WHOLE T6 TRADE (docs/trade-candidates.md, accepted): the keyboard
  // is not on any hot path, keys are milliseconds apart (hps_io holds ps2_key until the
  // next event, and the host's USB HID poll dominates by milliseconds), and the VALUES
  // and the ORDER of the guest-visible bytes are unchanged - only the cycle the decision
  // lands on. tb_pc9821_kbd_pipeline.sv pins the new depth (both this stage and the
  // translation ROM's, which stage 1 rides on) as a contract rather than a comment.
  reg [7:0] key_q;                 // the dedup table's read register: NO power-up value
  /* verilator lint_off PROCASSINIT */   // the initialisers are the registers' power-up values
  reg [6:0] key_epoch = 7'd0;      // the generation tag the reset bumps (see the table below)
  /* verilator lint_on PROCASSINIT */
  reg [7:0] ev2_code;
  reg       ev2_lock;
  reg       ev2_pressed;
  reg       ev2_valid;
  // The dedup write that landed on the edge the current read was captured on, in DECODED
  // form: a block RAM hands back the OLD word of a same-address write, so this is how the
  // decision below sees it (see the bypass note at the table itself).
  reg [6:0] wq_addr;
  reg       wq_down;
  reg       wq_we;
  always @(posedge clk) begin
    ev2_code    <= event_code;
    ev2_lock    <= event_lock;
    ev2_pressed <= event_pressed;
    ev2_valid   <= ps_event && event_mapped;
  end

  // The decision itself, unchanged in shape - just reading the staged event and the
  // table's registered read (`key_q`) instead of the live event and a flop array.
  wire key_down_now = wq_we && (wq_addr == ev2_code[6:0]) ? wq_down :
                      (key_q[0] && (key_q[7:1] == key_epoch));   // entry live under THIS epoch
  wire normal_make = ev2_valid && !ev2_lock && ev2_pressed && !key_down_now;
  wire normal_break = ev2_valid && !ev2_lock && !ev2_pressed && key_down_now;
  wire lock_press = ev2_valid && ev2_lock && ev2_pressed &&
                    !key_down_now;   // M2: one toggle per PHYSICAL press
  wire event_valid = normal_make || normal_break || lock_press;
  wire [7:0] event_data = ev2_lock ?
      ((ev2_code == 8'h71) ?
       (lock_flags[2] ? (ev2_code | 8'h80) : ev2_code) :
       (lock_flags[3] ? (ev2_code | 8'h80) : ev2_code)) :
      (ev2_pressed ? ev2_code : (ev2_code | 8'h80));

  // NP2kai's keyboard_callback (io/serial.c) gates delivery on exactly one
  // condition -- the previously delivered byte has been read (its `status & 2`
  // check); it does not gate on the 8251 command bits at all. Also requiring
  // rx_enabled and !rts would swallow every keystroke, since the PC-98 BIOS asserts
  // RTS in its command byte.
  wire can_deliver = !status_reg[1];
  wire deliver_resp = can_deliver && (resp_count != 2'd0);
  wire deliver_key = can_deliver && (resp_count == 2'd0) && (fifo_cnt != 5'd0) && pace_ready;
  // THE RECEIVE STATUS'S FOUR EFFECTS, as strobes for the ONE next-state fold below:
  // the data-read clear, the command's error clear (bit 4 - both 0x3A and 0x32 carry it), the overflow flag (an event
  // that cannot enqueue because the FIFO is full) and the delivery set.
  wire st_read    = cs && rd && !a0;
  wire st_errclr  = cs && wr && a0 && !din[6] && din[4];
  wire st_overrun = !kbd_reset_now && event_valid && !enqueue_key;
  wire st_deliver = !kbd_reset_now && (deliver_resp || deliver_key);
  wire fifo_can_enqueue = (fifo_cnt < 5'd16) || deliver_key;
  wire event_enqueue = event_valid && fifo_can_enqueue;
  // THE hps_io-NORMALIZED PAUSE EVENT IS A TAP, NOT A HELD KEY. Its host stream carries
  // exactly ONE event: Main_MiSTer sends the raw PS/2 Pause make sequence
  // E1 14 77 E1 F0 14 F0 77 at key RELEASE and on every host autorepeat (user_io.cpp
  // send_keycode, `press != 1` - "pause does not have a break code"; press 2 is a repeat, and
  // this branch runs ahead of the other keys' `press > 1 && !use_ps2ctl` repeat filter, so a held
  // Pause is a train of taps), and sys/hps_io.sv:325 normalizes it to one
  // {pressed, extended, 0x77} token with NO Pause-release case. The make that token
  // translates to (0x60, STOP) could therefore never be broken: the key stayed down
  // and - STOP being typematic-repeatable (NP2kai keystat.tbl kbexflag row 0x60 is 0) -
  // the repeat engine re-emitted 0xE0/0x60 pairs forever, so any later keyboard poll
  // (Touhou 4 at startup) saw "the STOP key has been pressed". NP2kai's guest stream
  // for a Pause TAP is a make+break pair (sdl/kbtrans.c {RETROK_PAUSE, 0x60} feeds
  // keystat.c keystat_send: the make byte on the down event, code|0x80 on the up
  // event), so the tap queues its own break and is never marked down - one clean STOP
  // press per host event, with no stuck state and no typematic reachable from it.
  wire tap_event = (ev2_code == 8'h60);   // 0x60 has no other source in translate()
  wire tap_brk_set = normal_make && tap_event && event_enqueue;
  wire tap_enqueue = (tap_brk != 2'd0) && fifo_can_enqueue && !event_valid;
  // The typematic pair outranks nothing: a real key event and a Pause tap's break both
  // win, so a held key can never displace a press.
  wire repeat_push = (rep_pend != 2'd0) && fifo_can_enqueue && !event_valid && !tap_enqueue;
  wire [7:0] repeat_push_data = (rep_pend == 2'd2) ? (rep_key | 8'h80) : rep_key;
  wire enqueue_key = event_enqueue || tap_enqueue || repeat_push;
  wire [7:0] enqueue_data = event_enqueue ? event_data :
                            (tap_enqueue ? (8'h60 | 8'h80) : repeat_push_data);

  // THE KEYBOARD RESET'S OWN CYCLE (the 8251 bit-3 1-to-0 transition). As a
  // wire it can give explicit priority in the folds below: the reset is one
  // event like any other (the Single-Cycle Event Discipline), and every register it owns has ONE next-state per cycle,
  // `kbd_reset_now ? clear : normal_update`. The coincident deliver/enqueue is
  // discarded WITH the rest of what the receive side is holding - exactly what
  // NP2kai's keyboard_resetsignal() clears (keybrd.status, keybrd.ctrls,
  // keybrd.buffers).
  wire kbd_reset_now = cs && wr && a0 && !din[3] && cmd_bit3;
  // EVERY 8251 DATA WRITE WITH TxEN LOADS A COMMAND RESPONSE except one: an
  // unrecognized 0x9D parameter. NP2kai keystat.c keystat_ctrlsend case 0x9d
  // answers 0x60 (LED query) and 0x7x (LED set) and otherwise does NOTHING -
  // no second ACK and no NACK; QEMU hw/input/pc98-kbd.c likewise sends no
  // rejection byte. The old unconditional 0xFC here was a divergence from both
  // and could be consumed by the next 0x41/status read as a key or a response.
  // This strobe marks a load for the delivery fold, so it must stay low for the
  // ignored parameter too (an unread opcode ACK must not be discarded, and an
  // in-flight response's shift must not be deferred).
  wire cmd_9d_no_reply = cs && wr && !a0 && tx_enabled && cmd_pending &&
                         (cmd_opcode == 8'h9D) &&
                         (din != 8'h60) && (din[7:4] != 4'h7);
  wire resp_load = cs && wr && !a0 && tx_enabled && !cmd_9d_no_reply;
  // THE COMMAND RESPONSE'S OWN CLEAR (NP2kai keyboard_ctrl(), io/serial.c): queuing a
  // leading FA/FC -- every command arm below does -- clears keybrd.ctrls, so a command
  // response REPLACES a pending, unread command response. That unread remainder is not
  // only resp_shift (already overwritten by the load); it is also the byte already
  // delivered into rx_latch, which is what the ITF's `0x00`-then-`0x9F` identity probe
  // (BANK4@0x1988/0x1992) must NOT see: with it kept, the guest reads the stale 0xFC,
  // re-sends 0x9F, and the re-loaded response duplicates its 0xFA, so the probe's
  // `cmp al,0xA0` fails and the stage-0x27 `or [0x481],0x40` never runs. A key byte
  // (rx_is_resp = 0) is untouched: it is the FIFO's, not the control queue's.
  wire st_resp_clear = resp_load && rx_is_resp;

  // ---- THE RESET CLEAR, HALF 1 OF 2: A GENERATION TAG -----------------------------------
  // One write port cannot clear 128 words in one clk, and a 128-clk sweep cannot be waited
  // for, so the reset does not clear the array - it BUMPS `key_epoch`, and every word
  // carries the tag it was written under. A word written before a reset then reads as
  // not-down WITHOUT the memory being touched, which is the same guest-visible state the
  // flop array had (every key up) in one clk.
  //
  // ONLY THE MODULE RESET BUMPS IT. The 8251 bit-3 keyboard reset must NOT: it is a reset
  // of the KEYBOARD/USART record, not of the physical keys, and NP2kai keyboard_resetsignal
  // (io/serial.c) keeps keystat.ref - it only drops the parameter and the repeat buffer and
  // then keystat_resendstat re-announces what is still held. Clearing the dedup here
  // would make the model forget a held key, so the key's BREAK would not match
  // (normal_break needs key_down_now) and be swallowed - a held direction would stay down in
  // the guest until it was pressed again, and a re-delivered make (USB resync) would be taken
  // as a second press. Keeping the tag makes the held key survive exactly as the reference
  // expects; the module reset still clears everything, because keys held across a card
  // reload/reconfiguration are stale physical state the framework does not re-send.
  // The resend itself (keystat_resendstat) is deliberately NOT modelled: the 8251 reset
  // does not touch the guest's own key table, so the retained state already keeps the
  // guest consistent, while a resend walk would re-announce a key pressed during it (the
  // 128-clk race) and duplicate a press. The one cost - a make still sitting in the
  // receive buffer when the reset arrives is discarded with it - is recorded as a WAIVED
  // divergence in tb_pc9821_8251.
  //
  // ---- THE RESET CLEAR, HALF 2 OF 2: THE SWEEP THAT MAKES THE TAG EXACT -----------------
  // A tag WRAPS, and on the wrap a word stamped 2^7 bumps ago would read as live again -
  // i.e. a reset could revive the PRE-reset belief that a key is down, which is exactly the
  // belief the module reset exists to clear - and the 8251 reset does not bump, so
  // only the module reset's bumps can wrap it. So the tag alone is not the scheme: the
  // SWEEP is the clear, and the tag only makes it immediate.
  // The sweep walks key_state[0..127] and writes {current tag, 0} to every word whose tag is
  // STALE. That write is IDEMPOTENT and observationally a NO-OP - a stale word already reads
  // as not-down, so the sweep only makes the clear PHYSICAL - which is why it can run in the
  // background without touching a guest-visible value. Everything is stale after a bump, so
  // a word is physically cleared within 128 of its key's idle cycles of the bump, while the
  // tag needs 2^7 = 128 bumps to return to any stamp - and a module reset cannot be issued
  // back-to-back faster than the framework's own reset handshake, far more than 128 clk_sys.
  // No input the interface can present can revive a pre-reset belief.
  // The sweep is READ-GATED: it issues its read only while the event path does not need the
  // port (ps_event low), so an event's stage-1 read is never disturbed; and it clears a word
  // only when nothing wrote it on either edge since that read (the wq_* bypass and the
  // ev2_kwe priority below), so it can never clobber a fresh write back to not-down.
  wire       ev2_kwe   = rst_n && !kbd_reset_now && ev2_valid &&
                         (!ev2_pressed || event_enqueue);
  // The tap key is never marked down: its break is queued with its make (above), so
  // the dedup table must read it as released - a later tap's make then delivers again.
  wire [7:0] ev2_kdata = {key_epoch, ev2_pressed && event_enqueue && !tap_event};
  wire [6:0] ev2_kaddr = ev2_code[6:0];
  // ...the sweep's own state: the next address to read, the address key_q holds, and
  // whether key_q is a sweep read at all (it is not, in the clk after any ps_event).
  // They are powered up so that 4-state sim has no X on the memory's read address or its
  // write enable from t=0: these are plain registers, so a power-up value is safe here (the
  // ban above is on the register that CAPTURES a memory read).
  /* verilator lint_off PROCASSINIT */
  reg [6:0] sw_cnt = 7'd0;
  reg [6:0] sw_addr_q = 7'd0;
  reg       sw_rd = 1'b0;
  /* verilator lint_on PROCASSINIT */
  wire       sw_owns  = !ps_event;                            // the event's stage-1 read wins
  wire [6:0] k_raddr  = sw_owns ? sw_cnt : event_code[6:0];
  wire       sw_clear = sw_rd && (key_q[7:1] != key_epoch) &&
                        !(wq_we && (wq_addr == sw_addr_q)) &&
                        !(ev2_kwe && (ev2_kaddr == sw_addr_q));
  always @(posedge clk) begin
    // ONE READ PORT AND ONE WRITE PORT, deliberately: a bypass mux ON the read (the other
    // way to handle a same-address read-during-write) makes Quartus REFUSE the RAM - Info
    // (276009) "key_state is uninferred due to unsupported read-during-write behavior" -
    // and puts all 128 words back into logic. The bypass is on the CONSUMER side, in wq_*:
    // the read is the table's OLD word, and the decision the event one clk later substitutes
    // the write that landed on the same edge.
    key_q <= key_state[k_raddr];
    if (ev2_kwe)       key_state[ev2_kaddr] <= ev2_kdata;
    else if (sw_clear) key_state[sw_addr_q] <= {key_epoch, 1'b0};
    // ...the write that landed on THIS edge, decoded, for the next decision and for the
    // sweep's clobber guard. One clk of history is enough: any older write is in the table.
    wq_addr <= ev2_kaddr;
    // The bypass's down bit must match the table's write (ev2_kdata above): the
    // tap's make is never marked down, so its bypass must read released too - a
    // stray wq_down=1 would make key_down_now believe STOP is held for one cycle
    // and swallow a second tap landing on that edge.
    wq_down <= ev2_pressed && event_enqueue && !tap_event;
    wq_we   <= ev2_kwe;
    // ...and the sweep's read issue and advance, only while it owns the port.
    sw_rd <= sw_owns;
    if (sw_owns) begin
      sw_addr_q <= sw_cnt;
      sw_cnt    <= sw_cnt + 7'd1;
    end
  end

  always @(posedge clk) begin
    // The PS/2 event edge detector tracks THROUGH reset (the
    // L2 replay): `ps_event` is an EDGE of the hps_io toggle bit, and an
    // edge detector that stops tracking across reset sees a phantom edge on the
    // first cycle after release and replays the last (or X) key. Tracking is
    // unconditional, so a completed event held on ps2_key is consumed DURING the
    // reset - a fresh ps2_key[10] toggle after release is the only thing that
    // fires an event.
    ps2_key_prev <= ps2_key_q[1];
    rst_n_prev   <= rst_n;
    // The generation-tag bump: ONE increment per reset ASSERTION, which is why the module
    // reset (a level) is edge-detected here rather than folded into the `!rst_n` arm -
    // bumping every clk it is held would walk the epoch by the pulse's LENGTH, and it is
    // the count of bumps, not of clks, that the tag has to absorb. The 8251 bit-3 keyboard
    // reset deliberately does NOT bump it (see the HALF 1 note above): the physical keys
    // did not move, and NP2kai keyboard_resetsignal keeps keystat.ref so their breaks still
    // match. This is the word-by-word clear of the dedup array, in one clk, for the
    // module reset.
    if (rst_n && !rst_n_prev) key_epoch <= key_epoch + 7'd1;
    if (!rst_n) begin
      status_reg   <= 8'd0;
      rts          <= 1'b1;
      rx_enabled   <= 1'b0;
      tx_enabled   <= 1'b0;
      rx_latch     <= 8'hFF;
      rx_is_resp   <= 1'b0;
      cmd_bit3     <= 1'b0;
      fifo_head    <= 4'd0;
      fifo_tail    <= 4'd0;
      fifo_cnt     <= 5'd0;
      resp_shift   <= 24'd0;
      resp_count   <= 2'd0;
      cmd_pending  <= 1'b0;
      cmd_opcode   <= 8'd0;
      lock_flags   <= 4'd0;
      repeat_inhibit <= 1'b0;
      xfer_div     <= '0;
      pace_div     <= '0;
      rep_key      <= 8'hFF;
      rep_pend     <= 2'd0;
      rep_timer    <= 26'd0;
      tap_brk      <= 2'd0;
      // The key state and the 8251 sequence telemetry are reset state too:
      // dedup state kept across a reset would swallow the first make of every key that was
      // down before it (the epoch bump above clears it), and an unreset `ctrl_writes` X-locks the dbg_ctrl0/1 latches in 4-state sim.
      ctrl_writes  <= 8'd0;
      dbg_events   <= 8'd0;
      dbg_delivered<= 8'd0;
      dbg_rd_data  <= 8'd0;
      dbg_wr_ctrl  <= 8'd0;
      dbg_last_del <= 8'd0;
      dbg_ctrl0    <= 8'd0;
      dbg_ctrl1    <= 8'd0;
    end else begin

      // Data reads clear RXRDY - and with it the IRQ line, which is RXRDY's own
      // level (the assign at the bottom). Both land in status_reg's ONE next-state
      // fold near the queue below; delivery has priority if a new byte becomes
      // available on the same edge, avoiding a lost receive byte.

      // 8251 mode/command state.
      if (cs && wr && a0) begin
        if (ctrl_writes == 8'd0)      dbg_ctrl0 <= din;
        else if (ctrl_writes == 8'd1) dbg_ctrl1 <= din;
        if (ctrl_writes != 8'hFF) ctrl_writes <= ctrl_writes + 8'd1;
        // 0x43 is always the command register. The 8251 has no positional
        // state here: NP2kai's keyboard_o43 stores every write (io/serial.c:55-66)
        // and the only "mode register" path is a write to 0x41 while TxEN is
        // clear (serial.c:45). Our value-classified cfg_phase machine consumed
        // phases without storing anything, so a control sequence could be
        // swallowed -- writing 0x40, 0x5E, 0x05 left TxEN clear, whereas NP2kai
        // ends with cmd = 0x05. Removed, along with the phase register.
        if (din[6]) begin
          rts        <= 1'b1;
          rx_enabled <= 1'b0;
          tx_enabled <= 1'b0;
        end else begin
          // The error clear (bit 4) lands in status_reg's ONE next-state fold near
          // the queue below, where the keyboard reset wins as the priority
          // expression - not because of where any NBA sits.
          rts        <= din[5];
          rx_enabled <= din[2];
          tx_enabled <= din[0];
        end

        // THE KEYBOARD RESET. Bit 3's 1-to-0 transition discards everything the
        // receive side is holding, which is what NP2kai's keyboard_o43 does by calling
        // keyboard_resetsignal() (io/serial.c): it clears keybrd.cmd, keybrd.status and
        // BOTH byte queues, the control responses and the keys.
        //
        // The ITF performs exactly that transition in its POST init sequence:
        // BANK4@0x04BEA writes 0x3A and BANK4@0x04BF6 writes 0x32, differing in bit 3
        // ALONE, and the same pair appears at BANK4@0x04BDF/0x06709, BANK7@0x067B5 and
        // BIOS.ROM@0x167B5. On a plain 8251 bit 3 is SBRK, which is meaningless to a
        // keyboard controller, so NP2kai's reading of it as a keyboard reset is what
        // makes the firmware's pulse meaningful.
        //
        // FOLDED, not positioned: every receive-side register this touches has
        // its single next-state (status_reg's and the IRQ line's is the fold's
        // reset arm near the queue below) in this arm or in that fold, with the
        // reset winning over the same-cycle deliver/enqueue arms by their
        // `!kbd_reset_now` guards. It does NOT touch
        // rts/rx_enabled/tx_enabled: NP2kai assigns keybrd.cmd = dat AFTER the reset, so
        // the new command byte's enables survive and only the receive-side record goes.
        if (kbd_reset_now) begin
          resp_shift <= 24'd0;
          resp_count <= 2'd0;
          rx_is_resp <= 1'b0;
          fifo_head  <= 4'd0;
          fifo_tail  <= 4'd0;
          fifo_cnt   <= 5'd0;
          // ...and the half-written keyboard command, which is the part easiest to
          // forget. NP2kai's keyboard_resetsignal() calls keystat_ctrlreset(), whose
          // first act is `keyctrl.reqparam = 0` -- so a reset abandons a command that
          // was waiting for its parameter. Without this, cmd_pending survives the
          // reset and the NEXT command byte is eaten as the parameter of the stale
          // opcode instead of being decoded: the guest gets the wrong response, or
          // none, and the command it meant to send is never carried out. The ITF
          // writes this exact pair during POST (BANK4@0x04BEA/0x04BF6), so the state
          // can be stale on real firmware and not only in a bench.
          cmd_pending <= 1'b0;
          cmd_opcode  <= 8'd0;
          // THE KEY STATE IS DELIBERATELY NOT CLEARED HERE. The bit-3 reset is a
          // reset of the keyboard/USART record, not of the physical keys, and
          // NP2kai keyboard_resetsignal (io/serial.c) keeps keystat.ref - only
          // keystat_ctrlreset drops the half-written parameter and keystat_resendstat
          // drops the repeat buffer. Clearing the dedup (an epoch bump here)
          // would make the held key's BREAK fail normal_break's key_down_now test and be
          // swallowed, so a held direction would stay down in the guest until it was
          // pressed again; it would also let a re-delivered make through as a second
          // press. The typematic state DOES go (keystat_resendstat resets its
          // keyrepeat buffer), so a held key does not resume repeating from a
          // stale timer.
          rep_key   <= 8'hFF;
          rep_pend  <= 2'd0;
          rep_timer <= 26'd0;
        end
        cmd_bit3 <= din[3];
      end

      // Keyboard-side command protocol. NP2kai recognizes 9C/9D/9F; 95/96
      // are enabled for newer keyboards. 0x99 answers FA FB here (QEMU
      // hw/input/pc98-kbd.c); NP2kai keystat.c has no 0x99 case and would
      // reject it with 0xFC. No capture arbitrates, so the QEMU response is
      // kept (it is the "Not Ready?" FB a PC-9801-119 reports) and the
      // divergence is recorded in tb_pc9821_8251 as a WAIVED line.
      if (cs && wr && !a0 && tx_enabled) begin
        if (cmd_pending) begin
          cmd_pending <= 1'b0;
          case (cmd_opcode)
            8'h95: begin
              resp_shift <= {16'd0, 8'hFA};
              resp_count <= 2'd1;
            end
            8'h9C: begin
              // The parameter is the repeat setting (NP2kai keystat.c keeps it
              // in keyctrl.keyrep). 0x70 is "inhibit key repeating" and must
              // stop the typematic engine; any other value re-enables it, and
              // its TIMING is not modelled (NP2kai's keyrepeat_proc does not
              // model it either). ACK both bytes, as the Xe10's PC-9801-119
              // keyboard does (s9C -> FA, s70 -> FA).
              repeat_inhibit <= (din == 8'h70);
              if (din == 8'h70) rep_pend <= 2'd0;
              resp_shift <= {16'd0, 8'hFA};
              resp_count <= 2'd1;
            end
            8'h9D: begin
              if (din == 8'h60) begin
                resp_shift <= {8'd0, (8'h70 | {4'd0, lock_flags}), 8'hFA};
                resp_count <= 2'd2;
              end else if (din[7:4] == 4'h7) begin
                lock_flags <= din[3:0] & (LOCK_NUM | LOCK_CAPS | LOCK_KANA);
                resp_shift <= {16'd0, 8'hFA};
                resp_count <= 2'd1;
              end else begin
                // Unrecognized LED parameter: NP2kai keystat.c keystat_ctrlsend
                // case 0x9d does NOTHING (no second ACK, no NACK) and QEMU
                // pc98-kbd.c likewise sends no rejection byte. Load nothing;
                // cmd_9d_no_reply keeps resp_load low so an unread opcode ACK is
                // not discarded and an in-flight response still shifts.
              end
            end
            default: begin
              resp_shift <= {16'd0, 8'hFC};
              resp_count <= 2'd1;
            end
          endcase
        end else begin
          case (din)
            8'h95, 8'h9C, 8'h9D: begin
              cmd_opcode  <= din;
              cmd_pending <= 1'b1;
              resp_shift  <= {16'd0, 8'hFA};
              resp_count  <= 2'd1;
            end
            8'h96: begin
              // Keyboard ID: NP2kai keystat_ctrlsend answers FA A0 83; the 0x85 was
              // QEMU's byte and the primary reference is NP2kai.
              resp_shift <= {8'h83, 8'hA0, 8'hFA};
              resp_count <= 2'd3;
            end
            8'h99: begin
              resp_shift <= {8'd0, 8'hFB, 8'hFA};
              resp_count <= 2'd2;
            end
            8'h9F: begin
              resp_shift <= {8'h80, 8'hA0, 8'hFA};
              resp_count <= 2'd3;
            end
            default: begin
              resp_shift <= {16'd0, 8'hFC};
              resp_count <= 2'd1;
            end
          endcase
        end
      end

      // Typematic auto-repeat (NP2kai keystat.c keyrepeat_proc): a held repeatable key
      // re-emits break+make after REPEAT_DELAY, then every REPEAT_INTERVAL, until its own
      // break arrives. break-then-make is what NP2kai's two keyboard_send() calls produce.
      // Placed before the key-state block so a break in the same cycle wins the race.
      // Folded under the keyboard reset: its arm clears rep_* (below), and a
      // same-cycle push must not resurrect any of it.
      // The 0x9C 0x70 "inhibit key repeating" command stops the engine while held
      // (repeat_inhibit); the timer freezes rather than resetting, so lifting the
      // inhibit resumes the countdown where it stopped.
      if (!kbd_reset_now && rep_key != 8'hFF && !repeat_inhibit) begin
        if (rep_pend == 2'd0) begin
          if (rep_timer != 26'd0) rep_timer <= rep_timer - 26'd1;
          else begin
            rep_pend  <= 2'd2;
            rep_timer <= REPEAT_INTERVAL;
          end
        end else if (repeat_push) begin
          rep_pend <= rep_pend - 2'd1;
        end
      end

        // The M2 mechanical-lock dedup and the typematic/lock bookkeeping it gates, one
        // pipeline stage behind the event that caused them: `key_down_now` and the words
        // of `key_state` are written by the table's own always block above, and this arm
        // keeps the records that hang off the decision (the lock toggle and the repeat
        // timer). Folded under the keyboard reset: the reset
        // bumps the epoch, and a decision landing in its cycle is discarded WITH the
        // enqueue next to it, so the two can never disagree. M2 mechanical-lock dedup
        // (NP2kai keystat.c one alternating byte per PHYSICAL press): the table gates the
        // press exactly as it gates a normal make and clears on the release, so a
        // duplicate make -- a USB re-enumeration re-delivery, a resync/replay, or
        // Menu->KANA typematic -- re-neither re-toggles the lock nor emits a spurious
        // lock byte.
        if (!kbd_reset_now && ev2_valid) begin
          if (ev2_lock) begin
            if (ev2_pressed) begin
              if (event_enqueue) begin
                if (ev2_code == 8'h71) lock_flags <= lock_flags ^ LOCK_CAPS;
                else lock_flags <= lock_flags ^ LOCK_KANA;
              end
            end
          end else begin
          if (ev2_pressed && event_enqueue && !tap_event) begin
            if (!nonrep(ev2_code)) begin
              rep_key   <= ev2_code;
              rep_timer <= REPEAT_DELAY;
              rep_pend  <= 2'd0;
            end
          end else if (!ev2_pressed) begin
            if (ev2_code == rep_key) begin
              rep_key  <= 8'hFF;
              rep_pend <= 2'd0;
            end
          end
        end
      end

      // The queue's single next-state per cycle: under the
      // keyboard reset NOTHING on the receive side moves - the reset arm owns
      // the indices and the count, and the pre-reset enqueue/deliver are dropped
      // with the rest of the record instead of resurrecting head+1/tail+1 and a
      // delivered stale byte.
      if (!kbd_reset_now) begin
        if (enqueue_key) begin
          fifo[fifo_head] <= enqueue_data;
          fifo_head <= fifo_head + 4'd1;
        end
        // (an event that cannot enqueue - a full FIFO - sets the overrun flag in
        // status_reg's fold below, as st_overrun.)
        if (deliver_key) fifo_tail <= fifo_tail + 4'd1;

        case ({
          enqueue_key, deliver_key
        })
          2'b10:   fifo_cnt <= fifo_cnt + 5'd1;
          2'b01:   fifo_cnt <= fifo_cnt - 5'd1;
          default: ;  // simultaneous enqueue/dequeue leaves count unchanged
        endcase
      end

      // The Pause tap's queued break: ONE next-state per cycle.
      // A keyboard reset drops it WITH the make it belongs to - both were in the queue
      // the reset just flushed, so the orphan break must not outlive it.
      // The tap break count: reset drops every owed break with the makes it belongs
      // to (the FIFO the reset just flushed held them), an enqueue consumes one, and a
      // make owes one. Enqueue and make-set cannot coincide (tap_enqueue needs
      // !event_valid; tap_brk_set needs normal_make), so the order is a priority, not
      // a same-cycle race.
      if (kbd_reset_now)    tap_brk <= 2'd0;
      else if (tap_enqueue) tap_brk <= tap_brk - 2'd1;
      else if (tap_brk_set) tap_brk <= tap_brk + 2'd1;

      // The telemetry counts only what survives the fold (the bus-access counts
      // are unconditional: the reset write IS a control write).
      if (!kbd_reset_now && ev2_valid)                               dbg_events    <= dbg_events + 8'd1;
      if (!kbd_reset_now && (deliver_key || deliver_resp))           dbg_delivered <= dbg_delivered + 8'd1;
      if (cs && rd && !a0)                         dbg_rd_data   <= dbg_rd_data + 8'd1;
      if (cs && wr && a0)                          dbg_wr_ctrl   <= dbg_wr_ctrl + 8'd1;

      // Control responses have priority over normal key traffic, as in NP2kai.
      // DEFER-NOT-LOSE: a command response loaded in this
      // exact clk must keep the NEW response. The in-flight byte still reaches
      // the guest (deliver-first, the order NP2kai's serial callback gives: the
      // byte already in keybrd.data when the write lands), and the deliver's
      // shift/decrement bookkeeping DEFERS to the load. A response arriving
      // mid-response replaces the unread remainder exactly as NP2kai does it:
      // keystat_ctrlsend -> keyboard_ctrl() clears keybrd.ctrls on the leading
      // FA/FC before queueing the new bytes (io/serial.c).
      if (!kbd_reset_now && st_resp_clear) begin
        // The command response loaded in this clk replaces the unread one: discard the
        // delivered control byte with the remainder (NP2kai keybrd.ctrls = 0). The new
        // response delivers on the next clk, when status_reg[1] is clear again.
        rx_latch   <= 8'hFF;
        rx_is_resp <= 1'b0;
      end else if (!kbd_reset_now && deliver_resp) begin
        dbg_last_del <= resp_shift[7:0];
        rx_latch   <= resp_shift[7:0];
        rx_is_resp <= 1'b1;
        if (!resp_load) begin
          resp_shift <= {8'd0, resp_shift[23:8]};
          resp_count <= resp_count - 2'd1;
        end
      end else if (!kbd_reset_now && deliver_key) begin
        dbg_last_del <= fifo[fifo_tail];
        rx_latch   <= fifo[fifo_tail];
        rx_is_resp <= 1'b0;
      end else if (!kbd_reset_now && st_read) begin
        // The byte was consumed: it is no longer an unread remainder.
        rx_is_resp <= 1'b0;
      end

      // THE RECEIVE STATUS'S ONE NEXT-STATE.
      // The data-read clear, the error clear, the overflow flag and the delivery set
      // are folded into ONE expression, so no same-clk pair can resurrect or drop
      // another's bit. The old last-wins chain had three broken collisions: a same-clk
      // data read + overflow RESURRECTED RXRDY from the pre-read value (so the guest's
      // next 0x41 read returned the ALREADY-read rx_latch as a duplicate key byte), a
      // same-clk error-clear + overflow lost the 0x38 clear, and a same-clk overflow +
      // deliver lost the overrun flag. Priority in the fold: the keyboard reset clears
      // everything; a delivery WINS the RXRDY bit over the coincident read (deliver-
      // first, the order NP2kai's serialized callback gives - a byte landing on a read
      // edge must not be lost); the overrun flag and the error clear are independent
      // bits and both land.
      status_reg <= kbd_reset_now ? 8'd0 :
                    ((status_reg & ~(st_read       ? KST_RXRDY : 8'h00)
                                 & ~(st_resp_clear ? KST_RXRDY : 8'h00)
                                 & ~(st_errclr ? (KST_PARITY | KST_OVERRUN | KST_FRAMING) : 8'h00))
                     | (st_overrun ? KST_OVERRUN : 8'h00)
                     | (st_deliver ? KST_RXRDY : 8'h00));

      // The RE-POKE divider: RESTARTED by every request rise (a delivery -
      // st_deliver is the cycle the rise lands in), so the first re-stroke of a
      // fresh byte is one FULL transfer tick after the request it could re-fire.
      // A normal service's [dispatch, read] window is inside that first tick and
      // therefore contains no dip at all: with the free-running divider the
      // dip's recovery edge could land between the acknowledge and the handler's
      // 0x41 read, re-arm the edge-latched PIC, and survive the read - after EOI
      // IRQ1 fired again and the handler (which reads 0x41 WITHOUT checking
      // RXRDY) re-processed the stale byte as a second keypress
      // (double typing). The dip's own recovery does not restart the
      // divider: the wrap is already one tick away from it.
      xfer_div <= st_deliver ? XFER_ONE :
                  (xfer_div == XFER_LAST) ? '0 : xfer_div + XFER_ONE;

      // THE PRESENTATION PACE's ONE NEXT-STATE (Single-Cycle Event Discipline): the
      // keyboard reset has priority (it flushes the receive side, so the first byte
      // after it is immediate again, exactly like the first after reset); a key
      // delivery reloads the tick; otherwise it drains. The reset arm above owns the
      // module-reset value, and this is the ONLY other writer of pace_div.
      pace_div <= kbd_reset_now ? '0 :
                  deliver_key    ? XFER_LAST :
                  (pace_div != '0) ? pace_div - XFER_ONE : '0;
    end
  end

  // THE IRQ LINE IS THE REQUEST HELD HIGH - WITH THE NP2kai RE-POKE. While a delivered
  // byte waits unread the line holds (RXRDY's own level: qemu pc98-kbd.c:470 raises it
  // from KST_RXRDY exactly, and tb_pc9821_kbd_reset pins the hold), but once per
  // transfer tick it dips for one clk, so the request arrives as a fresh rising edge.
  // The consumer is the edge-latched PIC (pc9821_pic.sv: "set on a rising edge of IR,
  // held until INTA clears the serviced bit. A still-held level does NOT re-set after
  // INTA (no new edge)"), and NP2kai re-pokes pic_setirq(1) at EVERY keyboard transfer
  // tick while the receive side is not empty (io/serial.c keyboard_callback) - so an
  // acknowledge that is not followed by a 0x41 read is RE-REQUESTED at the next tick,
  // instead of the byte sitting forever with no interrupt (the dispatched-but-never-
  // read wedge the EMM386 trace's unread byte shows). The read clears RXRDY and with
  // it the line and the re-strokes (io/serial.c keyboard_i41: status &= ~2, and
  // pic_resetirq(1) is the same withdrawal here, since the line IS the request).
  //
  // st_read is the ATOMIC CANCEL of the dip (the double-type fix): the read's status
  // clear only lands the cycle AFTER its strobe is sampled, so a dip whose RECOVERY
  // edge fell in the strobe's own cycle would still rise (status_reg[1] not yet
  // cleared) and arm the PIC for a byte being consumed right there. Forcing the line
  // low while the strobe is up cancels that recovery edge with the clear itself - no
  // dip may land after (or across) a read that clears RXRDY.
  assign irq = status_reg[1] && !st_read && (xfer_div != '0);
  assign dout     = a0 ? (status_reg | 8'h85) : rx_latch;
  assign dbg_rts  = rts;
  assign dbg_rx_en = rx_enabled;
  // Host keyboard LEDs, in hps_io's {scrolllock, numlock, capslock} order, from the lock
  // state on every change (NP2kai reloadled()). KANA has no host lamp and takes
  // scrolllock; NUM takes numlock and CAPS takes capslock.
  assign led_status = {lock_flags[3], lock_flags[0], lock_flags[2]};

endmodule

`default_nettype wire
