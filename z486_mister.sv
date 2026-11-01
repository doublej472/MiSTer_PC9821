`timescale 1ns / 1ns

// The module is named `emu` and the file is named after the project revision, because MiSTer
// requires its top-level module to be called `emu` -- the framework loads the RBF by filename and
// looks for that module inside it. DECLFILENAME is therefore not fixable and is not a defect.
/* verilator lint_off DECLFILENAME */
// THE PORT LIST IS THE FRAMEWORK'S PHYSICAL PIN-OUT, and several pins exist because MiSTer
// requires them rather than because this core reads them. The unused ones, each with its reason:
// SD_MISO and SD_CD are the direct-SPI SD path, and the core reaches the card through the HPS;
// UART_CTS, UART_RXD and UART_DSR are the RECEIVE side, and the debug UART is transmit-only;
// USER_IN is the I/O-board input port, unused on a machine whose input is a PS/2 keyboard and
// mouse; and OSD_STATUS is read by hps_io, not by the core.
/* verilator lint_off UNUSEDSIGNAL */
module emu
(
	input         CLK_50M,
	input         RESET,
	// The MiSTer HPS bus. Its width and bit layout are the framework's (sys/hps_io.sv's
	// [45:0] port, which sys_top.v drives as {f1, HDMI_TX_VS, clk_100m, clk_ihdmi, ...});
	// these port declarations mirror sys/emu_ports.vh, so they move together. Verilator
	// reports two things about it and both are properties of the framework's bus rather
	// than of this design. It is an inout that hps_io drives and reads bidirectionally, so
	// the net's direction depends on machine state and Verilator cannot optimize it
	// (UNOPTFLAT: circular combinational logic), and the same net is both clocked and
	// asynchronous (SYNCASYNCNET). The framework's own cores carry the same two warnings.
	/* verilator lint_off UNOPTFLAT */
	/* verilator lint_off SYNCASYNCNET */
	inout  [45:0] HPS_BUS,
	/* verilator lint_on SYNCASYNCNET */
	/* verilator lint_on UNOPTFLAT */

	output        CLK_VIDEO,
	output        CE_PIXEL,
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output  [1:0] VGA_SL,
	output        VGA_SCALER,
	output        VGA_DISABLE,

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,
	output  [1:0] BUTTONS,

	input         CLK_AUDIO,
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,

	inout   [3:0] ADC_BUS,

	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on DECLFILENAME */

localparam CLOCK_RATE_HZ = 90_000_000;
// CLOCK_RATE_HZ is ALSO the SDRAM controller's clock: the controller and its PHY run on clk_sys
// (sdram_sync_bridge, FREQ = CLOCK_RATE_HZ), so there is no separate SDRAM clock and no
// clock-domain crossing.

// hps_io's PS/2 DEVICE EMULATION IS NOT BUILT (PS2DIV 0 at the hps_io instance below): it
// re-serialises the HPS's keyboard and mouse bytes as PS/2 clock/data lines for a core that wants a
// PS/2 bus, and this core reads the PARSED ps2_key/ps2_mouse words instead (pc9821_system marks the
// keyboard's PS/2 lines "genuinely unread", and the mouse lines have no reader here). With a
// divider the HPS's 0x21 poll returns {has_data, data} from a receiver the core never drives (its
// PS/2 outputs are tied idle-high), i.e. has_data 0; without one it returns 0. The parsed words, the
// LED status and the 0x1F capability answer (PS2WE stays 1) do not depend on the divider.
// (The divider was CLOCK_RATE_HZ / 25_000: one PS/2 bit is 40 us.)

// THE INSTRUCTION TRACE IS COMPILED OUT BY DEFAULT, and build_profile.py rewrites this line for the
// 'trace' profile in the same way it rewrites CLOCK_RATE_HZ. It is a build-time constant rather
// than a runtime switch because the shipped bitstream must not change: with TRACE_EN 0 the trace
// instance does not exist at all, and the only other difference is one arm of the UART FIFO arbiter
// whose condition is a constant the fitter removes.
localparam TRACE_EN = 1'b0;
// THE SERIAL CONSOLE'S PERFORMANCE LOG IS COMPILED OUT BY DEFAULT TOO, and build_profile.py
// rewrites this line for the 'trace' profile in the same way it rewrites TRACE_EN. This is the
// watchdog/PRF/GFX telemetry pc9821_system emits on core_dbg_uart_byte/core_dbg_uart_we, which the
// debug UART's FIFO arbiter below shares with the banner and the trace. With PERF_LOG_EN 0 the
// telemetry section does not exist at all and the core ties dbg_uart_we off, so the arbiter's
// `core_dbg_uart_we && ...` arm is a constant the fitter removes.
localparam PERF_LOG_EN = 1'b0;
// WHICH I/O-LATENCY PROFILE the bus implements, threaded into pc9821_system and on into
// pc9821_iobus the same way CLOCK_RATE_HZ becomes SYS_FREQ. build_profile.py rewrites this line
// for the 'iofaithful' profile. A COMPILE-TIME choice only (no OSD bit, no status[] bit, no
// runtime mux): 0 = "min", today's class table, bit-identical at every clock; 2 = "faithful", the
// machine's measured per-class per-direction access times (docs/probes/IO.TXT). See
// pc9821_iobus.sv's IO_LATENCY_PROFILE for the values.
localparam [1:0] IO_LATENCY_PROFILE = 2'd0;
// WHETHER THE MPU-PC98II MIDI CARD EXISTS, and with it the core's MIDI-out path over the
// framework's UART (MiSTer's "UART Mode -> MIDI", which the ARM routes to USB MIDI or to a
// network MidiLink peer). It threads into pc9821_system and on into pc9821_device_select, the
// iobus's decode and pc9821_mpu the same way IO_LATENCY_PROFILE does, and build_profile.py
// rewrites this line (mpu_en: on in every preset except trace, --no-mpu opts out). A COMPILE-TIME choice
// only (no OSD bit, no status[] bit, no runtime mux): with 0 the card's branch const-folds away
// (the feature costs 26-50 LABs).
localparam MPU_EN = 1'b1;
// HOW SDRAM_CLK LEAVES THE CHIP. 0 = today's: PLL output 1, phase-shifted (tools/profile_gen.py
// derive_sdram_phase). 1 = an output DDIO cell clocked by clk_sys itself (inverted, T/2), so the
// launch clock and dq_r's capture clock share the clk_sys net up to the IOE and STA's clock
// pessimism removal covers the PLL/clock-control spread; it is what closes the SDRAM read capture
// at 110/120 MHz (the CL3 builds), and it cannot hold below ~100 MHz (hold at 80 MHz extrapolates
// to -1.6 ns). build_profile.py rewrites this line from clk_sys (>= 100 MHz = 1, the same
// threshold as sdram.v's CL3), and the generated SDC follows the same value. A COMPILE-TIME
// choice only: the unselected branch const-folds away.
localparam SDRAM_CLK_DDIO = 1'b0;
// THE RUN-TIME SDRAM_CLK PHASE INSTRUMENT, a MEASUREMENT build (src/pc9821/core/pc9821_sdram_phase_ctl.sv):
// 1 generates the main PLL with its dynamic-phase-shift ports in use and puts a guest-driven
// stepper on the device bus at 0x5FF0/0x5FF2 (tools/hwprobe/sdshmoo sweeps the SDRAM window from
// DOS). build_profile.py rewrites this line (sdram_phase_dyn, --dbg-sdram-phase: OFF in every
// preset, refused with the DDIO SDRAM_CLK, whose clock is not output 1). A COMPILE-TIME choice:
// with 0 nothing is built - the PLL's phase ports exist on its wrapper but are tied off and
// unconnected inside it (tools/profile_gen.py), the device decode is the base one.
localparam SDRAM_PHASE_DYN = 1'b0;
// MEASUREMENT OVERRIDES of the SDRAM controller's timing table (sdram.v DBG_CL / DBG_TRCD_TRP), for
// test builds only: build_profile.py rewrites these lines (--dbg-sdram-cl2 writes 2 and keeps the
// phase-shifted SDRAM_CLK structure at any clock; --dbg-sdram-trcd-cycles N writes N). 0 = the
// values derived from CLOCK_RATE_HZ, which every preset builds.
localparam integer SDRAM_DBG_CL = 0;
localparam integer SDRAM_DBG_TRCD_TRP = 0;
// The SDRAM DQ read-capture cell (sdram.v DQ_IN_DDIO, whose note says why): 1 = an explicitly
// instantiated IOE input DDIO cell, 0 = a fabric register the fitter packs into that cell.
// build_profile.py rewrites this line (sdram_dq_ddio) and renders the SDC's capture collection
// from the same value. A COMPILE-TIME choice only: the unselected branch const-folds away.
localparam SDRAM_DQ_DDIO = 1'b1;
// The SDRAM output-register cells (sdram.v OUT_DDIO, whose note says why): 1 = every SDRAM output
// and DQ output-enable register is an explicitly instantiated IOE cell, 0 = fabric registers the
// fitter packs into those cells. build_profile.py rewrites this line (sdram_out_ddio) and renders
// the SDC's output-cell exception from the same value. A COMPILE-TIME choice only: the unselected
// branch const-folds away.
localparam SDRAM_OUT_DDIO = 1'b1;
// ONE IDE HARD DISK, always bank 0's master (IDE unit 0) whatever CDROM_EN says (the fixed
// layout). hps_io slot 3 is an unused index (no second disk), so the CD keeps slot 4 and the
// MGLs that name it stay valid.
// THE CD-ROM (ATAPI on the built-in IDE, always bank 1's master: src/pc9821/storage/pc9821_atapi.sv;
// without it bank 1 is empty).
// With 1 the OSD offers slot 4 ("S4,ISOPCD,Mount CD-ROM"), hps_io
// declares it and pc9821_system builds the drive; with 0 none of it exists. The OSD entries and
// the slot count are their own profile-rewritten LINES (CONF_STR_CD - the HDD's eject, plus the
// CD's mount and its eject on status[11], and with CDROM_AUDIO_EN the "CD audio volume" field on
// status[66:64]; and HPS_VDNUM: 3 without the CD, 5 with it, slot 3
// tied off), for the same reason CONF_STR_HEADER is: a string cannot be built conditionally
// without NULs. build_profile.py rewrites all three together and `--check` holds them together.
localparam CDROM_EN = 1'b1;
// The CD-DA player of that drive (PLAY AUDIO, PAUSE/RESUME, READ SUB-CHANNEL's position and the
// audio stream into the cdda ring). Follows the drive; a data-only drive is CDROM_AUDIO_EN 0.
localparam CDROM_AUDIO_EN = 1'b1;
// A DEBUG INSTRUMENT (build_profile.py --cdrom-log): the CD drive's command log on the debug UART,
// through the telemetry's FIFO arm, which is free when PERF_LOG_EN is 0. Off in every preset.
localparam CDROM_LOG_EN = 1'b0;
// THE DEBUG-UART INSTRUMENT FRAMEWORK (build_profile.py --dbg-gdc / --dbg-cpu / --dbg-snoop /
// --dbg-trig ...; docs/mister-testing.md "The debug UART"). Every
// one is a compile-time constant, OFF in every preset, and build_profile.py rewrites these lines
// together with the qsf record: with all off nothing below is instantiated (pc9821_system's
// generate-ifs), and they share the CD log's UART arm, so they are 0 whenever PERF_LOG_EN is 1.
localparam DBG_GDC_EN = 1'b0;
localparam DBG_CPU_EN = 1'b0;
localparam DBG_SAMPLE_MS = 10;
localparam DBG_SNOOP_EN = 1'b0;
localparam [31:0] DBG_SNOOP_LO = 32'h00000000;
localparam [31:0] DBG_SNOOP_HI = 32'h00000000;
localparam DBG_TRIG_KIND = 0;
localparam [31:0] DBG_TRIG_ADDR = 32'h00000000;
localparam [15:0] DBG_TRIG_CS = 16'h0000;
localparam [31:0] DBG_TRIG2_LO = 32'h00000000;
localparam [31:0] DBG_TRIG2_HI = 32'h00000000;
localparam DBG_ARM_S = 0;
localparam DBG_POST = 32;
// Whether anything but the reset banner can enqueue into the debug UART FIFO from the core's arm.
localparam DBG_UART_EN = CDROM_LOG_EN || DBG_GDC_EN || DBG_CPU_EN || DBG_SNOOP_EN || (DBG_TRIG_KIND != 0);
// THE ANALOG VIDEO CONVERTER (build_profile.py vga_dbl_en; README "Running", the "Analog video" OSD item).
// VIDEO_DBL_EN builds pc9821_line_doubler: the GDC's ~24.8 kHz lines sent twice at ~49.7 kHz for VGA
// monitors that cannot sync to 24 kHz. It is a compile-time knob; whether it runs is the OSD's
// "Analog video" field (status[81:80]), whose option list - with the "Scanlines" field the doubler
// adds - is the profile-rewritten CONF_STR_VIDEO line, which ends with the separator that closes the
// video section (so it is never empty, and a build with no converter has that one separator). The analog modes are VGA Native 24 kHz and
// Doubled 49 kHz only (no 15 kHz TV converter, no composite/S-Video encoder).
localparam VIDEO_DBL_EN = 1'b1;
localparam CONF_STR_VIDEO = "O[81:80],Analog video,Native 24kHz,Doubled 49kHz;O[83:82],Scanlines (doubled),None,25%,50%,75%;-;";
localparam CONF_STR_CD = "T[8],Eject HDD;S4,ISOPCD,Mount CD-ROM;T[11],Eject CD-ROM;O[66:64],CD audio volume,0 dB,-2 dB,-4 dB,-6 dB,-8 dB,-10 dB,-12 dB,Off;";
localparam HPS_VDNUM = 5;
// THE G3 GATHER SESSION'S ENTRY COUNT: how many same-row PEGC packed stores one SDRAM request carries. This is
// the ONE value both sides of the contract take - pc9821_pegc_storebuf's grouping and
// sdram.v's session engine - so a change is made here and nowhere else. The rate/area sweep
// priced K = 2/3/4/8; 4 is the deployed point (3.2 stores per 2 KiB row at stride 640).
localparam GATHER_K = 4;
// The OSD header's FIRST element, which is where the framework parses the core name and the
// UART/MIDI declarations (Main_MiSTer/user_io.cpp:754-820 parses element 1 for `UART<speeds>`
// and `MIDI<speeds>`; an empty element declares neither, so no UART page is offered at all).
// It has two forms: with MPU_EN 1, a core name, the UART speed pair and the MIDI token (this
// line); with MPU_EN 0, the eight-byte "PC9821;;", which declares no UART page.
// IT IS ITS OWN LOCALPARAM BECAUSE A STRING CANNOT BE BUILT CONDITIONALLY: Verilator zero-pads
// the shorter branch of a string ternary to the longer one's width and does it on the HIGH side,
// so a ternary between the two forms makes the eight-byte one a 37-byte element whose first 29
// bytes are NULs - which would move the bitstream and corrupt the OSD. So build_profile.py
// rewrites this line (and only this line) together with MPU_EN, and `--check` holds the two
// together.
localparam CONF_STR_HEADER = "PC9821;UART115200(Turbo 115200),MIDI;";
// Cache sizes, reduced from the 8 KB default to leave routing headroom (the design sits near the device
// limit and the conservative, template-default fit settings must keep working).
// The caches are M10K-backed, so this buys block RAM and cache control logic
// without changing any architectural behaviour.
localparam DCACHE_SET_BITS = 6;   // dcache size: 8 = 16KB, 7 = 8KB, 6 = 4KB
localparam ICACHE_SET_BITS = 6;   // icache size: 8 = 16KB, 7 = 8KB, 6 = 4KB
localparam ENABLE_X87 = 1'b0;     // PC-9821: x87 intentionally disabled
// The CD-DA path - the cdda sample ring and resampler - exists only for the CD drive's player:
// pc9821_atapi streams the audio sectors of the CD slot into it (its 6144-word ring alone is
// 21 M10K: src/soc/cdda.v's bank note). It follows the player
// (CDROM_AUDIO_EN), so a build without a CD - or with a data-only one - has no CD-DA logic.
// ao486's hps_ext EXT-command client is NOT used: Main_MiSTer serves it only for x86 core names
// (todo item 106), and the drive here reads its own image slot.
localparam CDDA_EN = CDROM_AUDIO_EN;

localparam CONF_STR = {
	CONF_STR_HEADER,
	"-;",
	// THE FIRMWARE PACK, the menu's first option (the BIOS ROM set comes before everything it
	// boots). Nothing depends on its POSITION: Main_MiSTer (menu.cpp at 13f1de9) takes the
	// load's index from the digit of `F0` (menu.cpp:2425 `if (p[idx] >= '0' && p[idx] <= '9')
	// ioctl_index = p[idx] - '0';`), hps_io reports that index as ioctl_index, and an MGL's
	// `<file ... index="0">` finds the entry by type and index wherever it sits (menu.cpp:2030
	// `num == mgl->item[mgl->current].index && (p[0] == mgl->item[mgl->current].type)`), so
	// moving the line moves no load.
	"F0,BIN,Load BIOS ROM;",
	"-;",
	// THE DRIVES: each Mount directly followed by its own Eject, in the order HDD, CD-ROM,
	// FDD1, FDD2. The floppy drives carry the PC-98's own names, FDD1 and FDD2 - hps_io slot 1
	// is FDD1 and slot 2 is FDD2 (S0 the hard disk, S4 the CD). A slot is named by the digit
	// of its `S{n}` entry, not by its position (Main_MiSTer at 13f1de9: menu.cpp:2462
	// `ioctl_index = p[idx] - '0';`, mounted with that index, user_io.cpp:2363
	// `spi_uio_cmd8(UIO_SET_SDSTAT, (1 << index) | ...)`, which sys/hps_io.sv:461 turns into
	// `img_mounted <= io_din[VD:0] ...`), so the display order moves no slot.
	// ONE EJECT PER IMAGE SLOT (osd-mount): an explicit unmount that does not depend on what
	// Main_MiSTer's own file browser offers. pc9821_mount_eject turns each into the slot's mount
	// event with img_size 0 - the sub-sector unmount every consumer already reads - so a floppy
	// or CD eject is a media change (no reset) and a hard-disk eject resets once, exactly as a
	// mount of that slot does.
	"S0,IMGHDIVHD,Mount HDD;",
	// The HDD's eject ("T[8],Eject HDD;"), and with the CD-ROM its "S4" mount and
	// "T[11],Eject CD-ROM;" after it: the profile-rewritten CONF_STR_CD line (see above). The
	// HDD's always-present eject leads it so the line is never empty. Slot 3 has no entry.
	// WITH THE CD DRIVE'S AUDIO PLAYER (CDROM_AUDIO_EN) the line ends with
	// "O[66:64],CD audio volume,0 dB,-2 dB,-4 dB,-6 dB,-8 dB,-10 dB,-12 dB,Off;": a runtime gain on
	// the CD-DA channel, like a real CD drive's volume wheel (pc9821_osd decodes the position to
	// pc9821_audio_volume's code). Position 0 is 0 dB, the unity level shipped before the
	// field existed (NP2kai's -6 dB is a step); the list descends to Off. status[66:64]
	// is in hps_io's status[79:64] word, which no field of this core has ever used.
	CONF_STR_CD,
	// The floppy image slots: one per drive, as the machine has. The second drive is the same
	// medium as the first with its own image, its own track
	// register (NP2kai fdc.treg[us]) and its own position. The extension list is a hint to
	// the file browser; the media module decides from the CONTENT (a D88 whose fd_type
	// major nibble is 3, or a body whose size is one of NP2kai's 1024-byte-sector rows).
	"S1,D88FDDHDM,Mount FDD1;",
	"T[9],Eject FDD1;",
	"S2,D88FDDHDM,Mount FDD2;",
	"T[10],Eject FDD2;",
	"-;",
	// THE MACHINE: RAM Size, CPU Speed and the Keyboard layout, one group.
	// The guest RAM size. The pack sits at the MODULE CEILING (ram_size_max below),
	// not at the selected size, so changing this takes effect on an OSD Reset without
	// moving the pack; a size above the
	// installed module's ceiling needs a core reload. pc9821_system.sv's size code is
	// 0..6 = log2(MiB), 7 the 96 MiB ceiling.
	//
	// THE LIST IS ROTATED so entry 0 is the 16 MB default, and that is not a style
	// choice: MiSTer passes OPTION INDEX 0 for every field when a core has no stored
	// config and CONF_STR has no syntax for a default, so an ascending list cannot
	// also put 16 MB first. Entry 0 correct makes a card with NO config file behave
	// exactly like one with a zeroed config.
	//
	// 16 MB is the default because a 1 MB guest cannot run the Xe10 BIOS at all -- it
	// freezes with nothing on screen. pc9821_osd.sv owns the list-position-to-code
	// mapping; the pack/VRAM layout and the per-size SDRAM budget are
	// docs/pc9821-port-status.md.
	"O[63:61],RAM Size,16M,32M,64M,96M,1M,2M,4M,8M;",
	// CPU Speed: the LIST POSITION goes straight to cpu_throttle's speed_sel,
	// whose rate_khz() table (src/z486/cpu_throttle.sv) owns position -> rate; the labels are
	// that table's rates, in its order (tools/check_osd_contract.py holds the two together).
	// Entry 0 is Full - a strict no-op - so a card with no config file runs at full speed.
	// Only the CPU slows (a gated CPU clock); the bus and every device keep their rates.
	"O[17:14],CPU Speed,Full,33 MHz,25 MHz,16 MHz,12 MHz,8 MHz,6 MHz,4 MHz,3 MHz,2 MHz,1.5 MHz,1 MHz,0.75 MHz,0.5 MHz;",
	// THE HOST KEYBOARD'S LAYOUT: which symbols the four keys that differ between a US and a
	// JIS keyboard give (pc9821_kbd.sv translate(), THE LAYOUT; README "Keyboard" lists them).
	// A runtime setting, applied at the next key press with no reset: it is the user's
	// keyboard, not a build constant or a machine strap. A key held across a change still
	// breaks as the key it made (pc9821_kbd's held-layout record, tb_pc9821_kbd_layout).
	// POSITION 0 IS US, the layout the core translated the backslash key in before the option
	// existed; swapping the two labels here and in pc9821_osd flips the default. status[51] has
	// never held another field, so an existing config reads US.
	"O[51],Keyboard,US,JIS;",
	"-;",
	// ==== THE DIP SWITCH PAGE =================================================================
	// Every relevant DIP switch / BIOS setting sits in this dedicated DIP Switch submenu.
	// `P{#}` is the framework's display GROUPING - `P1,Title`
	// opens the sub-page and every entry carrying the `P1` tag inside its bit spec is listed
	// under it - so this moves NO status bit: every index below is the one it had, saved
	// configs and benches keep their meaning, and the tag is written BEFORE the option letter
	// (`P1O[32]`, the form the frozen Template_MiSTer/Template.sv and PCXT_MiSTer use, and the
	// same rule the docs' d5P1o2 example states: the tag precedes the option it scopes).
	// The page holds the two boot-time STRAPS this core answers - the port-0x31 GDC clock and
	// the port-0xF0 machine ID, both latched at machine reset / reload - the POST-time BIOS
	// setup hold - all of it applied at machine reset / reload, never under a running guest.
	// The configuration stores are a static, reset-seeded view (no reset/zero actions).
	"P1,DIP Switch;",
	"P1-;",
	// WHICH MACHINE'S PORT-0xF0 MACHINE-ID STRAP the core answers, selected to match the
	// loaded pack (the pack file IS the firmware set; the MGL chooses Xe10 or Xe). The two
	// ITFs read the strap's bit 5 differently: the Xe10 (entry 0, the config-less default)
	// answers its MEASURED 0xA9, the Xe answers 0x89 (derived: 0xA9 with bit 5 clear, the
	// byte the Xe ITF's BANK4@0xF81DF branch needs -- unmeasured on a real Xe). ONLY THE
	// SETS THAT EXIST ARE OFFERED: Xe10 and Xe. The field is four bits on [31:28] (the LUT
	// in pc9821_iobus handles all 16 indices, the rest answering the measured Xe10 strap
	// 0xA9). Bits 28-31 are otherwise unread and undeclared. THE SELECTION APPLIES ONLY AT MACHINE RESET /
	// RELOAD: pc9821_iobus latches the field on the core's reset/reload strobe (its reset,
	// driven with `reset || !cpu_run`), so a mid-run change cannot move the strap under the
	// running firmware (tb_pc9821_bios_select).
	"P1O[31:28],Machine,Xe10,Xe;",
	// THE GDC CLOCK, 2.5 / 5 MHz. This is a BOOT-TIME STRAP, not a runtime switch, and it is
	// modelled as the machine really has it: PC-9821 port 0x31 bit 7 ("DIP switch 2", which
	// the measured Xe10 answers 0xF3 - bit 7 SET - i.e. 2.5 MHz). The BIOS reads the strap
	// once at POST (BIOS.ROM@0xFD93C -> work area 0x54D bit 5), derives the games' flag
	// 0x54D bit 2 from it, and TH01/TH03 then build the SCROLL im bit or refuse to run from
	// it. Nothing is seeded into a store and nothing is published by the core: the real
	// firmware does the whole derivation, so this field changes exactly one bit the guest can
	// read. IT IS LATCHED AT MACHINE RESET / RELOAD (pc9821_iobus's gdc_strap_eff, on the
	// same `reset || !cpu_run` strobe as the Machine field), so a mid-run change cannot move
	// the clock under the running firmware - which is also why a change needs a reset to be
	// seen at all, exactly like the machine's own SETUP item.
	// THE SAME STRAP IS ALSO WHAT THE SOFTWARE-DIP REGISTER 0x851E'S PARITY BIT FOLLOWS
	// (pc9821_iobus's dip2_parity): the authentic ITF verifies that register as a MERGE with
	// port 0x31 and requires the result to have odd parity, so the strap and the store can
	// never disagree - which is what stops the ITF's SET THE SOFTWARE DIP-SWITCH repair loop
	// (item 94: the software-DIP store, its parity bit and the strap).
	// POSITION 0 IS 2.5 MHz AND THAT IS LOAD-BEARING: a card with no config file passes 0 for
	// every field, and 2.5 MHz is the measured machine and what the boot golden is pinned at.
	// THE RECORD AT CG STORE 0x810 IS NOT THIS SETTING: it is the ITF's own configuration
	// mirror (only BANK4 selects CG code 0x2056), its sum check and repair paths are
	// the ITF's own, and seeding a guessed bit there cannot reach
	// 0x54D at all.
	"P1O[32],GDC Clock,2.5 MHz,5 MHz;",
	// The FDD-mode switch, port 0x00BE bit 2 (MAME pc9801.cpp DSW3:1 "FDD Fix Mode"). Both
	// settings exist on the machine; the measured unit is Fixed (docs/probes/FDMODE-XE10.TXT).
	// POSITION 0 IS AUTO, a deliberate default: with Fixed, POST leaves the 640 KB
	// floppy interface uninitialised and a 2DD boot disk that addresses it (INT 1Bh DA 0x70) gets
	// no drive. Read by POST, so a change applies at the next reset. status[38] has never held
	// another field (37:35 was the removed base-memory field), so old configs read Auto.
	"P1O[38],FDD mode,Auto,Fixed;",
	// ==== THE HARDWARE-SWITCH FIELDS ====
	// The board's PHYSICAL switch bank, the eight memory-switch cells at 0xA3FE2 + i*4 in the
	// text-VRAM tail (NP2kai bios/biosmem.h MEMB_MSW1..8). The authentic firmware READS these
	// and writes neither field: 0xA3FF2's high nibble goes to port 0x00BE (the FDC's
	// channel-group register) at every boot (BANK7@0x5991-0x59A9 `mov ah,[es:0x3ff2] / and
	// ah,0xF0 / cmp ah,0x20 / cmp ah,0x40 / out 0xBE,al`), and 0xA3FEA's bits 2:0 are the base
	// memory size (BANK4@0x5C3C `mov al,[es:0x3fea] / and al,7 / inc al / shl al,1` = (n+1)
	// 64 KB units; NP2kai generic/np2info.c:113-120 decodes the same field as (n+1)*128 KB and
	// fills work-area BIOS_FLAG1 from it at bios.c:236). Nothing else in the ROM set writes
	// either field (the only writes to those cells are the ITF's `or byte es:[0x3FEA],8`
	// marker at BANK4@0x1D15 and the dormant PCI bank's `and byte [es:0x3ff2],0x0F` at
	// BANK0@0x1208, both OUTSIDE the fields above). The 0xA3FF2 nibble is the machine's switch
	// and the OSD is the only way to set one without opening the case; the 0xA3FEA base-memory
	// code is NOT offered because the real Xe10 has no SETUP/DIP option that changes it (its
	// SETUP menu carries no such item, and NP2kai takes the value from the memory switch, not from a guest setting),
	// so the core hardcodes it to the measured 640 KB (pc9821_crtc's MSW_BASEM_CODE).
	// THE ENTRY-0 LABELS ARE THE MEASURED MACHINE and the lists are NOT reordered for tidiness:
	// a card with no config file passes 0 for every field, and 0 must be the captured
	// machine's own switch state or the boot golden moves.
	// THE ONLY SETTINGS OFFERED ARE THE ONES A REFERENCE PINS. For 0xA3FF2[7:4] - the
	// BOOT/FDD nibble - NP2kai reads the cell twice: bios.c:254 as the FDD equip-size class
	// (0x20 = 640 KB, anything else 1 MB) and bios1b.c:883-926 as a BOOT-DEVICE selector
	// (0x00 normal, 0x20 640 KB FDD, 0x40 1.2 MB FDD, 0x60 MO, 0xa0 SASI 1, 0xb0 SASI 2,
	// 0xc0 SCSI, default = ROM). The list exposes exactly those named codes, and the first
	// three entries keep the exact labels and nibbles the three-value list carried:
	// Auto = 0x0 (the MEASURED byte 0x01's own nibble and the ITF's `jz` keep class,
	// BANK7@0x5999), 640K = 0x20 (the value the authentic BIOS compares against at
	// BANK7@0x599B, `out 0xBE,al` = 0), 1M = 0x40 (BANK7@0x59A0 -> 3). The four APPENDED
	// entries MO/SASI1/SASI2/SCSI are NP2kai bios1b.c:903/906/910/914's boot-device codes
	// (0x60/0xa0/0xb0/0xc0). THE DIVERGENCE, STATED: the real Xe10 firmware does not select a
	// boot device from this nibble - its boot helper compares only 0x20/0x40 and KEEPS the
	// FDC's own reported mode for every other value (BANK7@0x599B-0x59A3), its SETUP's item
	// for the nibble is フロッピィディスクモード with the four values 640K/1M/自動（６４０Ｋ）/
	// 自動（１Ｍ） (BANK3@0x4a07-0x4b51), and NP2kai's own switch comment admits the reading is
	// a stand-in for the AL register (bios1b.c:883 `うぐぅ…本当はALレジスタの値から`; real
	// callers pass the boot device in AL/AH, bios1b.c:843-875). So on the machine the four
	// new entries land in the same keep class as Auto and change no boot decision: they seed
	// the reference's legal switch positions under the reference's names, and whether the
	// machine has ANY boot-order encoding is capture-pending (the SETUP item->cell map, todo
	// item 99). 0xA3FEA[2:0] - the
	// BASE (CONVENTIONAL) MEMORY - is NOT an OSD field: the machine has no way to change it,
	// so it is hardcoded to the measured 640 KB (code 4) inside pc9821_crtc and no list entry
	// is offered.
	// WHY THE FIELD IS ON status[42:40] AND NOT status[34:33]. Appending the four boot-device
	// entries makes the list 7 long, which does not fit the 2-bit field the three-value list
	// had - and widening it IN PLACE at [35:33] would have stolen the (since removed) Base
	// memory field's bit 35, silently re-mapping every saved config whose base-memory LSB was
	// set to a different machine (the exact trap an OSD option list's "the index IS the value"
	// carries). The field therefore moved to the free status[42:40]: entries 0..2 keep their
	// exact meaning, and a SAVED config from before the move reads 0 there - entry 0, the
	// measured machine - instead of being re-mapped to one nobody captured. The cost, stated:
	// a user who had entry 1 or 2 saved reverts to Auto once until they re-pick it.
	// APPLIED ONLY AT MACHINE RESET, and this entry carries a LIST POSITION rather than the
	// encoded switch value: pc9821_system forwards the position and pc9821_crtc decodes it,
	// latches the decoded nibble on the `reset || !cpu_run` strobe (rst_n_sys) and rewrites
	// the 0xA3FF2 cell with it (the 0xA3FEA base-memory code is hardcoded to 640 KB). Carrying
	// the position is what keeps an UNDRIVEN port meaning the captured machine - the same
	// convention the Machine field (0 = the Xe10 strap) and GDC Clock (0 = 2.5 MHz) use. A
	// mid-run change therefore cannot move the machine's switch under the running firmware
	// (tb_pc9821_msw_switch), and the positions the list does not offer decode to the measured
	// machine rather than to one nobody captured.
	"P1O[42:40],Boot order,Auto,640K,1M,MO,SASI1,SASI2,SCSI;",
	// Enter BIOS setup: hold HELP (NEC 0x3F) from reset so the ITF's POST reads it and
	// enters SETUP. The framework cannot hold a key across a core load (it sends one
	// edge per press), so the core synthesises the hold. Position 0 = Off = the default
	// a card with no config file passes. IT IS IN THIS PAGE for the same reason as the two
	// straps above: it is a decision taken BEFORE the guest runs that only takes effect at
	// POST, and the BIOS settings belong beside the DIP switches rather than split between
	// two places. One line moves it back to the root menu if that is preferred.
	"P1O[3],Enter BIOS setup (hold HELP),Off,On;",
	"-;",
	// Video options, and the controls the VIDEO section at the bottom of this file
	// reads. An UNDECLARED status-bit range is hard-wired to 0 -- nothing can set it.
	//
	// Every option uses the bracketed spelling: the framework parses a bracketed
	// range as written and applies the lower-case +32 offset only to the
	// un-bracketed form, so the O/o case carries no meaning here.
	//
	// There is no VSync field (the core keeps the guest's own raster as its only
	// option). The bits the RTL reads but no option declares are hard-wired to 0.
	"O[23:22],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[46:45],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	// With an analog converter built, its "Analog video" field (and the doubler's "Scanlines"
	// field) and the section's closing separator: the profile-rewritten CONF_STR_VIDEO line (see
	// above).
	CONF_STR_VIDEO,
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	// The PC-98 joypad has TWO buttons, not four: bits 4/5 of the game port are the pad's
	// buttons and bits 6/7 are their rapid-fire copies (NP2kai cbus/board118.c:315-341,
	// sdl/joymng.c:137 with the default sdl/np2.c:69; observed on the real machine). The
	// framework falls back to the SNES A/B/X/Y default list when CONF_STR declares no
	// joystick entry, which is the four-button prompt with two dead buttons; this `J` entry
	// (plain, NOT `J1`, so the keyboard is not locked to joystick mode) narrows the mapping
	// screen to the D-pad and these two. "Button N" also drives the framework's central
	// default map (joymapping.cpp is_fire), so SNES A/B land on joy bits 4/5, i.e.
	// joystick_dig_1[5:4] below.
	"J,Button 1,Button 2;",
	"V,v"
};

wire        clk_sys;
/* verilator lint_off UNUSEDSIGNAL */   // spare when SDRAM_CLK_DDIO
wire        clk_sdram_pin;    // SDRAM_CLK: clk_sys's frequency, phase-shifted for the device's setup
/* verilator lint_on UNUSEDSIGNAL */
wire        pll_locked;
wire        reset_async = RESET | ~pll_locked;
wire        reset_req = buttons[1] | status[0] | disk_change_reset;
// The reset synchroniser: `reset_async` SETS it asynchronously and the shift releases it
// synchronously, which is the right shape - deassertion is the hazardous half of an async reset.
// The declaration's initial value is the same state both reset paths force: without it simulation
// starts with the core held in reset as x, and Quartus implements register power-up values in the
// bitstream, so the card starts in reset identically.
/* verilator lint_off PROCASSINIT */
reg  [2:0]  reset_sync_r = 3'b111;
/* verilator lint_on PROCASSINIT */

// status carries the whole 128-bit OSD word and only the fields CONF_STR declares are read.
// hps_buttons[0] is the framework's second I/O-board button, and this machine has one reset
// action, on bit 1. ps2_mouse is hps_io's parsed PS/2 mouse packet (sys/hps_io.sv:106-107:
// [24] toggles once per packet, [23:16] Y, [15:8] X, [2:0] {middle, right, left}) and is
// the bus mouse's host input - it goes to pc9821_mouse through pc9821_system, which
// accumulates the deltas into the uPD8255 counters. ps2_mouse_ext (wheel and extra
// buttons) has no PC-98 protocol to map to and stays unread.
/* verilator lint_off UNUSEDSIGNAL */
wire [127:0] status;
// This is hps_io's own port name, and it differs from the top-level `BUTTONS` output (line 53,
// tied off below) by CASE ALONE -- which SIMILARNAME flags. tools/check_wiring.py pins the
// framework's reset path by asserting the exact text `reset_req = buttons[1] | status[0]`, so
// the port is not renamed here.
/* verilator lint_off SIMILARNAME */
wire  [1:0] buttons;
/* verilator lint_on SIMILARNAME */
wire [10:0] ps2_key;
wire [24:0] ps2_mouse;
wire [15:0] ps2_mouse_ext;
/* verilator lint_on UNUSEDSIGNAL */
wire        ps2_kbd_clk_out;
wire        ps2_kbd_data_out;
wire        ps2_kbd_clk_in;
wire        ps2_kbd_data_in;
// The device side of hps_io's PS/2 mouse SESSION is idle: the core consumes the parsed
// ps2_mouse fields above (the PC-98 bus mouse is a register device, not a PS/2 peripheral),
// so the clk/data inputs hps_io reads stay in the PS/2 idle state and its own device-facing
// outputs go nowhere.
/* verilator lint_off UNUSEDSIGNAL */
wire        ps2_mouse_clk_out;
wire        ps2_mouse_data_out;
/* verilator lint_on UNUSEDSIGNAL */
wire        ps2_mouse_clk_in  = 1'b1;
wire        ps2_mouse_data_in = 1'b1;

wire        core_ce_pixel;
wire        core_31k;      // 0x09A8 bit 0: the raster is on the 31 kHz dot clock (pc9821_system)
wire        vid_vmode;     // clk_vid level: the video PLL is in its 31 kHz configuration (hps_io new_vmode)
// THE VIDEO CLOCK (CLK_VIDEO): the video PLL's output, exactly dot-locked so every pixel and sync
// period is a constant number of clocks. The PLL is generated as the reconfigurable fractional-N
// variant at its FASTEST rate, 2 x 25.168 MHz = 50.336 MHz (the 31 kHz clock), so the cleaner's
// sync-length bound is sized from the generated rate; pc9821_vpll_ctl moves it to the 24 kHz
// configuration after lock and to the 31 kHz one whenever the guest sets 0x09A8 bit 0
// (pc9821_vclk_pkg: both settings in one place).
// Everything from pc9821_video_out's output to CLK_VIDEO runs on it.
wire        clk_vid;
localparam integer VIDEO_CLK_HZ = 50_336_015;
// The picture after the analog converters (the core's own when none is built or selected), on its
// own enable in the video clock domain: what the cleaner, gamma, video_freak and the framework see.
wire        vid_ce;
wire  [7:0] vid_r, vid_g, vid_b;
wire        vid_hs, vid_vs, vid_de;
wire  [7:0] clean_r, clean_g, clean_b;
wire        clean_hs, clean_vs, clean_de;
wire  [7:0] gamma_r, gamma_g, gamma_b;
wire        gamma_hs, gamma_vs, gamma_de;
wire  [7:0] core_r;
wire  [7:0] core_g;
wire  [7:0] core_b;
wire        core_hs;
wire        core_vs;
wire        core_de;
wire [15:0] core_audio_l;
wire [15:0] core_audio_r;
wire        core_bios_loaded;
wire        core_first_instruction;
wire  [7:0] core_dbg_uart_byte;
// pc9821_system's trace freeze trigger (a drawing burst's end or a page flip). Read only by
// the TRACE_EN ring, so the shipped profiles drive it and leave it unread (the cpu_cs waiver).
/* verilator lint_off UNUSEDSIGNAL */
wire        core_trace_trig;
/* verilator lint_on UNUSEDSIGNAL */
wire        core_dbg_uart_we;
// PC-98 crash-recorder / probe taps from pc9821_system (z486 dbg_* outputs). The crash
// recorder, its OSD debug view and its snapshot window read these; until they exist the
// taps are carried but unread, so the fitter drops them and they cost nothing.
/* verilator lint_off UNUSEDSIGNAL */
wire        core_dbg_gate_read;
wire [31:0] core_dbg_gate_addr;
wire  [2:0] core_dbg_pf_code;
wire [31:0] core_dbg_pf_addr;
wire [31:0] core_dbg_eflags;
wire        core_dbg_page_fault;
wire [31:0] core_dbg_walk_pde;
wire [31:0] core_dbg_walk_pte;
wire [31:0] core_dbg_cr3;
wire [15:0] core_dbg_SP;
wire        core_dbg_issue;
wire [31:0] core_dbg_issue_eip;
/* verilator lint_on UNUSEDSIGNAL */
// The instruction trace, if TRACE_EN built it. See pc9821_trace.sv for what the ring holds and why
// it is in M10K rather than SDRAM.
//
// cpu_cs and cpu_eip feed the trace and NOTHING ELSE, so with TRACE_EN 0 they are driven by the CPU
// and never read - which is what the shipped profiles compile, deliberately. Waived rather than
// declared conditionally: a conditional declaration and a conditional port connection would make
// the trace's wiring harder to follow than the warning it avoids.
/* verilator lint_off UNUSEDSIGNAL */
wire [15:0] cpu_cs;
wire [31:0] cpu_eip;
// The stall context is the CPU's OUTSTANDING REQUEST on the guest-memory port 0 - the address it
// is waiting on, and the valid/ready pair that says the wait never ended. The address carries the
// answer by itself, because an I/O port is below 0x10000 and GVRAM is at 0xA8000. It is driven
// from guest_mem0_* below (the same signals pc9821_system's ext_mem0_* ports carry).
wire [31:0] trace_ctx_addr;
wire        trace_ctx_valid, trace_ctx_ready, trace_ctx_write, trace_ctx_resp_valid;
/* verilator lint_on UNUSEDSIGNAL */
wire  [7:0] trace_byte;
wire        trace_we;
wire [19:0] sample_86_l;
wire [19:0] sample_86_r;
wire        speaker_out;
wire        speaker_out_audio;
wire  [1:0] beep_vol;
wire  [4:0] vol_master_l;
wire  [4:0] vol_master_r;
wire  [4:0] vol_voice_l;
wire  [4:0] vol_voice_r;
wire  [4:0] vol_cd_l;
wire  [4:0] vol_cd_r;
wire  [4:0] vol_midi_l;
wire  [4:0] vol_midi_r;
// The line-in volume pair had one reader, the "MT32 Volume Ctl" arm of vol_mt32_l/r, which read
// the undeclared status[25] and is folded away (the undeclared-option fold, below): pc9821_system still
// drives the pair and nothing here reads it.
/* verilator lint_off UNUSEDSIGNAL */
wire  [4:0] vol_line_l;
wire  [4:0] vol_line_r;
/* verilator lint_on UNUSEDSIGNAL */
wire  [1:0] vol_spk;
// vol_en is the mixer's output-switch vector (line_l, line_r, cd_l, cd_r, mic), NOT an hps_io
// signal: pc9821_system drives it hard-wired to 5'b11111 ("every path enabled") and this top only
// reads it through the instance port. Bits 2/1 gate the CD path (the mix_tmp sum below); bits 4/3
// selected the line path in the "MT32 Volume Ctl" arm of vol_mt32_l/r, which read the undeclared
// status[25] and is folded away, and bit 0 (mic) has no consumer here.
/* verilator lint_off UNUSEDSIGNAL */
wire  [4:0] vol_en;
/* verilator lint_on UNUSEDSIGNAL */
reg  [16:0] spk_out;
// The final DAC's sum: the -86 stream spans
// [+255,996, -239,616], CD adds +-32,768 and the speaker up to +24,576 (beep_vol
// 3 at the top status shift; see the note on the spk expression below), so the
// three-source sum spans [+313,340, -272,384] and needs 20 signed bits (range
// +-524,287). An 18-bit accumulator (range +-131,071) would wrap and
// hand the saturator the wrong rail/polarity. The one saturation of the whole
// machine's audio is the mix_dry saturate below - on the MASTER-SCALED sum,
// exactly ymfm's clamp16 / NP2kai's _saturation_s16 junction.
reg signed [19:0] mix_tmp_l;
reg signed [19:0] mix_tmp_r;
reg  [15:0] mix_dry_l;
reg  [15:0] mix_dry_r;
// Absorber for hps_io's sd_clk output. The core reaches the SD card through the HPS rather than
// driving the SPI pins itself, so this wire gives the output a landing place rather than leaving
// the port unconnected.
/* verilator lint_off UNUSEDSIGNAL */
wire        dummy_sd_clk;
/* verilator lint_on UNUSEDSIGNAL */
wire [35:0] ext_bus;
// MiSTer's bit-sliced gamma bus. hps_io drives [20:0] (hps_io.sv:247) - including bit 20, which
// is the CLOCK - and gamma_fast takes its clock from that bit (gamma_corr.sv:89) while driving
// bit 21 back. So one net is legitimately both a clock and data, which is what SYNCASYNCNET
// reports, and both ends are vendored framework modules: the top only wires them together.
/* verilator lint_off SYNCASYNCNET */
wire [21:0] gamma_bus;
/* verilator lint_on SYNCASYNCNET */
wire [12:0] arx;
wire [12:0] ary;
wire [15:0] status_menumask = 16'd0;
wire [127:0] status_in = 128'd0;
wire        status_set = 1'b0;
// The MiSTer 'info' bus, which a core uses to tell the framework something out of band
// (hps_io.sv:119-120 takes both as inputs, and :287-288 latches a byte on the rising edge of
// info_req). This core has nothing to report, and pc9821_system has no port that could produce
// one -- so both are TIED OFF here rather than left undriven. Undriven is not the same statement:
// an undriven input is a floating pin that only happens to read 0 once Quartus has tied it, and
// it reads x under Verilator.
wire        info_req = 1'b0;
wire [7:0]  info     = 8'h00;
wire [2:0]  ps2_kbd_led_status;
wire [2:0]  ps2_kbd_led_use = 3'b111;  // this core owns all three host LEDs
wire        video_rotated = 1'b0;

// The OSD's stored fields, decoded in one place. pc9821_osd.sv owns the mapping
// from a list position to the value the core acts on, and says why it is a module
// rather than a function here: the mapping is a contract, this tree's benches are
// unit benches that never elaborate the top level, and an untestable contract is one
// that gets discovered in the field. It has its own bench.
//
// `selected_ram_size` is the guest size code the clamp below and pc9821_system take.
wire [2:0]  selected_ram_size;
wire        bios_setup;
// The OSD GDC Clock field (status[32]), decoded: 1 = 5 MHz. It is not a status[] bit read
// anywhere else, and tools/check_osd_contract.py parses the CONF_STR entry above.
wire        gdc_clock_5m;
// The OSD FDD mode field (status[38]), decoded: 1 = Fixed (0x00BE bit 2).
wire        fdd_dip_fixed;
// The OSD Keyboard field (status[51]), decoded: 1 = JIS host layout, 0 = US.
wire        kbd_layout_jis;
// The OSD CD audio volume field (status[66:64]), decoded to pc9821_audio_volume's 5-bit gain
// code (31 = 0 dB, 0 = mute); constant 0 in a build without the CD drive's player.
wire  [4:0] cd_volume_code;
pc9821_osd #(.CD_AUDIO_EN(CDROM_AUDIO_EN)) u_osd (
  .osd_ram_size (status[63:61]),
  .osd_bios_setup(status[3]),
  .osd_gdc_clock(status[32]),
  .osd_fdd_mode (status[38]),
  .osd_kbd_layout(status[51]),
  .osd_cd_volume(status[66:64]),
  .ram_size_code(selected_ram_size),
  .bios_setup   (bios_setup),
  .gdc_clock_5m (gdc_clock_5m),
  .fdd_dip_fixed(fdd_dip_fixed),
  .kbd_layout_jis(kbd_layout_jis),
  .cd_volume_code(cd_volume_code)
);
// hps_io provides SIX gamepads, SIX paddles and SIX spinners. This is a PC: its input is a PS/2
// keyboard and mouse, and the joystick the core does support is the PC gameport mapping below,
// which reads joystick_0/1 and joystick_l/r_analog_0/1. The remaining four of each family are
// declared because hps_io drives them and an output needs a landing place; nothing here reads
// them, and the games for this machine predate every one of these device types.
/* verilator lint_off UNUSEDSIGNAL */
wire [31:0] joystick_0;
wire [31:0] joystick_1;
wire [31:0] joystick_2;
wire [31:0] joystick_3;
wire [31:0] joystick_4;
wire [31:0] joystick_5;
wire [15:0] joystick_l_analog_0;
wire [15:0] joystick_l_analog_1;
wire [15:0] joystick_l_analog_2;
wire [15:0] joystick_l_analog_3;
wire [15:0] joystick_l_analog_4;
wire [15:0] joystick_l_analog_5;
wire [15:0] joystick_r_analog_0;
wire [15:0] joystick_r_analog_1;
wire [15:0] joystick_r_analog_2;
wire [15:0] joystick_r_analog_3;
wire [15:0] joystick_r_analog_4;
wire [15:0] joystick_r_analog_5;
wire [7:0]  paddle_0;
wire [7:0]  paddle_1;
wire [7:0]  paddle_2;
wire [7:0]  paddle_3;
wire [7:0]  paddle_4;
wire [7:0]  paddle_5;
wire [8:0]  spinner_0;
wire [8:0]  spinner_1;
wire [8:0]  spinner_2;
wire [8:0]  spinner_3;
wire [8:0]  spinner_4;
wire [8:0]  spinner_5;
/* verilator lint_on UNUSEDSIGNAL */

// PC gameport joystick mapping (the undeclared-option fold of the dead OSD fields). The ancestor (ao486) shaped these words from five OSD fields - the per-stick
// disable status[50:49], the stick map status[48:47] (2 sticks / 2 wheels / 4-axes wheel),
// the button mode status[13:12] and the timing form status[59:58] - and this CONF_STR declares
// none of them, so MiSTer hands the core 0 for every one of those bits (an undeclared field is
// never set by the OSD) and the mapping was ALWAYS its 2'd0 arm: both sticks present, two
// joysticks, two buttons each, the IBM timed one-shot. The reads are folded to exactly that arm
// so the gameport's unreachable mode/timed/dis arms const-fold away. To offer a field again,
// declare it in CONF_STR and restore its read here.
wire [1:0]  joystick_dis   = 2'b00;
wire [13:0] joystick_dig_1 = joystick_0[13:0];
wire [13:0] joystick_dig_2 = joystick_1[13:0];
wire [15:0] joystick_ana_1 = joystick_l_analog_0;
wire [15:0] joystick_ana_2 = joystick_l_analog_1;
wire [1:0]  joystick_mode  = 2'd0;
wire [1:0]  joystick_timed = 2'd0;

// hps_io's two video-mode requests. forced_scandoubler (MiSTer.ini) turns on the analog line
// doubler when one is built (VIDEO_DBL_EN, below); direct video needs nothing from the core.
/* verilator lint_off UNUSEDSIGNAL */
wire        forced_scandoubler;
wire        direct_video;
/* verilator lint_on UNUSEDSIGNAL */
wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;
wire        ioctl_wait;
// hps_io's own image events; the core reads them through pc9821_mount_eject (img_mounted /
// img_size / img_readonly below), which merges the OSD's eject actions into them.
wire [HPS_VDNUM-1:0] hps_img_mounted;
wire        hps_img_readonly;
wire [63:0] hps_img_size;
wire [HPS_VDNUM-1:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;
// The OSD's eject actions, one per hps_io slot in slot order. EACH IS ONE `assign` so that
// tools/check_osd_contract.py can hold every `Eject X` trigger to the slot of its `Mount X`.
// status[11] is the CD's (a --cdrom build): it was only ever a T trigger, never a stored
// option, so no saved config can hold it set. Slot 3 (unused, kept so the CD stays slot 4)
// has no eject.
wire [HPS_VDNUM-1:0] eject_req;
assign eject_req[0] = status[8];    // T[8]  Eject HDD
assign eject_req[1] = status[9];    // T[9]  Eject FDD1
assign eject_req[2] = status[10];   // T[10] Eject FDD2
generate if (HPS_VDNUM > 3) begin : cd_slot_eject
	assign eject_req[3] = 1'b0;
	assign eject_req[4] = status[11];   // T[11] Eject CD-ROM
end endgenerate
// EVERY slot goes through the module, the CD's too: its "quiet channel" is then every slot's
// host mount, so an eject is never issued in a cycle a CD host mount is carrying its size.
pc9821_mount_eject #(.N(HPS_VDNUM)) mount_eject (
	.clk         (clk_sys),
	.hps_mounted (hps_img_mounted),
	.hps_size    (hps_img_size),
	.hps_readonly(hps_img_readonly),
	.eject_req   (eject_req),
	.img_mounted (img_mounted),
	.img_size    (img_size),
	.img_readonly(img_readonly)
);
// Disk-change reset: which SLOT's mount may ask for a platform reset. The decision lives in
// pc9821_disk_change_reset so that it is benchable (z486_mister.sv is in no Verilator bench's
// file list). Slot 0 (the ATA/HDD image) keeps the behaviour this core has always had; the
// floppy slots - slot 1 (FDC0, the OSD's "S1,D88FDDHDM,Mount FDD1;" entry) and slot 2 (FDD2, "S2")
// - must NOT re-POST the machine: a floppy swap reaches the guest on its next access to the
// drive, exactly as it does in NP2kai, whose image mount swaps the medium in place. The module
// takes the two-bit vector it was built around (its header explains why the floppy slot is
// present-but-ignored rather than absent), so the second floppy slot is deliberately not one
// of its inputs either.
wire        disk_change_reset;
pc9821_disk_change_reset disk_change_reset_gate (
	.clk         (clk_sys),
	.reset_async (reset_async),
	.img_mounted (img_mounted[1:0]),
	.pack_loaded (core_bios_loaded),
	.reset_req   (disk_change_reset)
);
wire [31:0] sd_lba [HPS_VDNUM];
wire [5:0]  sd_blk_cnt [HPS_VDNUM];
wire [HPS_VDNUM-1:0] sd_rd, sd_wr, sd_ack;
wire [12:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din [HPS_VDNUM];
// Slot 3: no device (an unused index, kept so the CD stays slot 4). Declared
// to hps_io only when the CD makes VDNUM 5; nothing requests on it.
generate if (HPS_VDNUM > 3) begin : unused_slot3
	/* verilator lint_off UNUSEDSIGNAL */
	wire slot3_unused = img_mounted[3] | sd_ack[3];
	/* verilator lint_on UNUSEDSIGNAL */
	assign sd_lba[3]      = 32'd0;
	assign sd_blk_cnt[3]  = 6'd0;
	assign sd_rd[3]       = 1'b0;
	assign sd_wr[3]       = 1'b0;
	assign sd_buff_din[3] = 16'd0;
end endgenerate
// Slot 4: the CD-ROM (CDROM_EN). Read-only: no write request and no core->host data leg.
wire        cd_mounted, cd_ack, cd_rd;
wire [31:0] cd_lba;
wire [5:0]  cd_blk_cnt;
generate if (HPS_VDNUM > 4) begin : cd_slot
	assign cd_mounted     = img_mounted[4];
	assign cd_ack         = sd_ack[4];
	assign sd_lba[4]      = cd_lba;
	assign sd_blk_cnt[4]  = cd_blk_cnt;
	assign sd_rd[4]       = cd_rd;
	assign sd_wr[4]       = 1'b0;
	assign sd_buff_din[4] = 16'd0;
end else begin : no_cd_slot
	assign cd_mounted = 1'b0;
	assign cd_ack     = 1'b0;
	// No slot 4: the drive does not exist either (CDROM_EN 0), so its request pins are constant.
	/* verilator lint_off UNUSEDSIGNAL */
	wire cd_req_unused = cd_rd | (|cd_lba) | (|cd_blk_cnt);
	/* verilator lint_on UNUSEDSIGNAL */
end endgenerate
wire        sd_buff_wr;
// The UPLOAD side of the hps_io ioctl path. The core loads its firmware pack through
// ioctl_download / addr / dout / wait and never uploads anything, so ioctl_upload, ioctl_rd and
// the file-extension word have no consumer. sdram_sz reports the fitted SDRAM module in 16 bits
// and only the low two distinguish the module sizes this core's OSD offers.
/* verilator lint_off UNUSEDSIGNAL */
wire        ioctl_upload;
wire        ioctl_rd;
wire [31:0] ioctl_file_ext;
wire [15:0] sdram_sz;
/* verilator lint_on UNUSEDSIGNAL */
wire [1:0] detected_ram_size = |sdram_sz[1:0] ? sdram_sz[1:0] : 2'd1;
// `selected_ram_size` comes from the pc9821_osd instance above, which owns the
// list-position-to-code mapping and the bench that walks every position. Nothing
// below depends on the list's ORDER, only on the code, so reordering the OSD list
// cannot move a size by accident.
//
// The hidden firmware reserve sits at the pack, which pc9821_system places at
// the MODULE CEILING (this ram_size_max), not at the selected guest size; GVRAM and
// the 256 KiB EMS/ROM-sum window sit above the pack (pc9821_memory_subsystem.sv).
// The ceiling therefore has to leave the module room for the reserve at the top of
// the guest range, and the clamp below keeps the SELECTED guest size at or under it
// so guest RAM can never overlap the pack. The per-module figures and the
// reserved-for-graphics reason are docs/pc9821-port-status.md's SDRAM budget table.
//
// Codes are monotone in the size, so the comparison picks the smaller guest.
wire [2:0] ram_size_max = detected_ram_size == 2'd1 ? 3'd4 :
                          detected_ram_size == 2'd2 ? 3'd5 : 3'd7;
wire [2:0] configured_ram_size = (selected_ram_size > ram_size_max)
                                ? ram_size_max : selected_ram_size;
// hps_io's clock and UART fields. The core reads the battery-backed calendar through
// pc9821_calendar rather than from this RTC, so only rtc[55:0] is consumed and the upper date
// bits are not; timestamp is the framework's Unix time and nothing here uses it; uart_speed
// selects the framework's UART baud, unused because the debug UART's rate is fixed by the
// defparam above.
/* verilator lint_off UNUSEDSIGNAL */
wire [64:0] rtc;
wire [32:0] timestamp;
wire [7:0]  uart_mode;
// The OSD's UART mode as Main_MiSTer sends it (user_io.cpp SetUARTMode:
// `spi_w((mode == 4 || mode == 5) ? 1 : mode);`, with menu.cpp's config_uart_msg[] =
// None, PPP, Console, MIDI, Modem): 3 is MIDI. The MPU-PC98II's line and the card's presence
// to the guest (pc9821_system's mpu_present) both follow it.
wire uart_midi_mode = (uart_mode == 8'd3);
wire [31:0] uart_speed;
/* verilator lint_on UNUSEDSIGNAL */
wire        debug_uart_tx;
wire        debug_uart_busy;
wire        mpu_uart_tx;
reg   [7:0] debug_uart_data;
reg         debug_uart_wr;
reg   [7:0] debug_uart_fifo [0:511];
reg   [8:0] debug_uart_fifo_wr;
reg   [8:0] debug_uart_fifo_rd;
reg   [9:0] debug_uart_fifo_count;
reg         debug_uart_enqueue;
reg         debug_uart_dequeue;
reg         debug_uart_banner_active;
reg   [4:0] debug_uart_banner_index;
reg         debug_uart_reset_d;
// Whether the FIFO will take a WATCHDOG byte presented this cycle. This is the whole enqueue
// decision below and not just "there is room": the reset banner and the instruction trace outrank
// the watchdog, so a byte is accepted only when that chain would actually select the watchdog
// source. pc9821_dbg_record holds each byte until this is high, which is what makes a report longer
// than the 512-entry FIFO lossless - the trace shares the FIFO at higher priority, so pacing is the
// one fix that can never drop a watchdog byte. CY advances regardless, so the report's
// ratios stay honest while the emission waits.
wire debug_uart_wdg_accept = core_dbg_uart_we && !debug_uart_banner_active && !trace_we &&
                             debug_uart_fifo_count != 10'd512;

function [7:0] debug_banner_char;
	input [4:0] index;
	begin
		case(index)
			5'd0:  debug_banner_char = "Z";
			5'd1:  debug_banner_char = "3";
			5'd2:  debug_banner_char = "8";
			5'd3:  debug_banner_char = "6";
			5'd4:  debug_banner_char = " ";
			5'd5:  debug_banner_char = "s";
			5'd6:  debug_banner_char = "t";
			5'd7:  debug_banner_char = "a";
			5'd8:  debug_banner_char = "r";
			5'd9:  debug_banner_char = "t";
			5'd10: debug_banner_char = 8'h0D;
			default: debug_banner_char = 8'h0A;
		endcase
	end
endfunction

assign gamma_bus = 'z;
// The PLL's dynamic-phase-shift ports (SDRAM_PHASE_DYN): the scan clock is the 50 MHz reference, not
// a clock of this PLL, so the stepper keeps running whatever the shift does. With SDRAM_PHASE_DYN 0
// phase_en is a constant 0 and the generated PLL does not connect the ports at all.
/* verilator lint_off UNUSEDSIGNAL */   // SDRAM_PHASE_DYN=0: the handshake and phase_done are unread
wire        sdph_step_req, sdph_step_up, sdph_phase_done;
/* verilator lint_on UNUSEDSIGNAL */
wire        sdph_step_ack, sdph_fault;
wire        sdph_phase_en, sdph_updn;
wire  [4:0] sdph_cntsel;
pll pll
(
	.refclk     (CLK_50M),
	.rst        (1'b0),
	.outclk_0   (clk_sys),
	.outclk_1   (clk_sdram_pin),
	.locked     (pll_locked),
	.phase_en   (sdph_phase_en),
	.scanclk    (CLK_50M),
	.updn       (sdph_updn),
	.cntsel     (sdph_cntsel),
	.phase_done (sdph_phase_done)
);
generate if (SDRAM_PHASE_DYN) begin : g_sdph_dps
	pc9821_sdram_dps sdph_dps (
		.clk(CLK_50M), .step_req_async(sdph_step_req), .step_up_async(sdph_step_up),
		.phase_done_async(sdph_phase_done), .phase_en(sdph_phase_en), .updn(sdph_updn),
		.cntsel(sdph_cntsel), .step_ack(sdph_step_ack), .fault(sdph_fault)
	);
end else begin : g_no_sdph_dps
	assign sdph_phase_en = 1'b0;
	assign sdph_updn     = 1'b0;
	assign sdph_cntsel   = 5'd0;
	assign sdph_step_ack = 1'b0;
	assign sdph_fault    = 1'b0;
end endgenerate

always @(posedge clk_sys or posedge reset_async) begin
	if (reset_async)
		reset_sync_r <= 3'b111;
	else if (reset_req)
		reset_sync_r <= 3'b111;
	else
		reset_sync_r <= {reset_sync_r[1:0], 1'b0};
end

hps_io #(
	.CONF_STR(CONF_STR),
	// The OSD string is served from a ROM (one M10K) instead of a 525-byte combinational mux on
	// byte_cnt. It is the framework's own option (sys/hps_io.sv confstr_rom): the ROM's registered
	// read returns rom[byte_cnt-1] one clk_sys after byte_cnt moves, and byte_cnt only moves on an
	// io_strobe, which sys_top makes a one-clock pulse of a handshaked GPO toggle - so at the next
	// strobe, when 'h14 samples conf_byte, the ROM has long since caught up and the byte is the one
	// the mux gave.
	.CONF_STR_BRAM(1),
	// ONE SLOT PER S-ENTRY. VDNUM is explicit in hps_io (the framework's own parameter,
	// not derived from CONF_STR): slot 0 the hard disk (S0), slot 1 FDD1 (S1), slot 2 FDD2
	// (S2) - three - and with the CD-ROM slot 4 (S4), which makes it five with slot 3 an unused,
	// tied-off index (kept so slot 4 does not move). The vector widths of
	// img_mounted/sd_rd/sd_wr/sd_ack and the slot count of sd_lba/sd_blk_cnt/sd_buff_din all
	// follow it.
	.VDNUM(HPS_VDNUM),
	.PS2DIV(0),
	.PS2WE(1),
	.WIDE(1)
) hps_io
(
	.clk_sys           (clk_sys),
	.HPS_BUS           (HPS_BUS),
	.joystick_0        (joystick_0),
	.joystick_1        (joystick_1),
	.joystick_2        (joystick_2),
	.joystick_3        (joystick_3),
	.joystick_4        (joystick_4),
	.joystick_5        (joystick_5),
	.joystick_l_analog_0(joystick_l_analog_0),
	.joystick_l_analog_1(joystick_l_analog_1),
	.joystick_l_analog_2(joystick_l_analog_2),
	.joystick_l_analog_3(joystick_l_analog_3),
	.joystick_l_analog_4(joystick_l_analog_4),
	.joystick_l_analog_5(joystick_l_analog_5),
	.joystick_r_analog_0(joystick_r_analog_0),
	.joystick_r_analog_1(joystick_r_analog_1),
	.joystick_r_analog_2(joystick_r_analog_2),
	.joystick_r_analog_3(joystick_r_analog_3),
	.joystick_r_analog_4(joystick_r_analog_4),
	.joystick_r_analog_5(joystick_r_analog_5),
	.joystick_0_rumble (16'd0),
	.joystick_1_rumble (16'd0),
	.joystick_2_rumble (16'd0),
	.joystick_3_rumble (16'd0),
	.joystick_4_rumble (16'd0),
	.joystick_5_rumble (16'd0),
	.paddle_0          (paddle_0),
	.paddle_1          (paddle_1),
	.paddle_2          (paddle_2),
	.paddle_3          (paddle_3),
	.paddle_4          (paddle_4),
	.paddle_5          (paddle_5),
	.spinner_0         (spinner_0),
	.spinner_1         (spinner_1),
	.spinner_2         (spinner_2),
	.spinner_3         (spinner_3),
	.spinner_4         (spinner_4),
	.spinner_5         (spinner_5),
	.status            (status),
	.buttons           (buttons),
	.ps2_key           (ps2_key),
	.ps2_kbd_clk_out   (ps2_kbd_clk_out),
	.ps2_kbd_data_out  (ps2_kbd_data_out),
	.ps2_kbd_clk_in    (ps2_kbd_clk_in),
	.ps2_kbd_data_in   (ps2_kbd_data_in),
	.ps2_kbd_led_status(ps2_kbd_led_status),
	.ps2_kbd_led_use   (ps2_kbd_led_use),
	.ps2_mouse_clk_out (ps2_mouse_clk_out),
	.ps2_mouse_data_out(ps2_mouse_data_out),
	.ps2_mouse_clk_in  (ps2_mouse_clk_in),
	.ps2_mouse_data_in (ps2_mouse_data_in),
	.ps2_mouse         (ps2_mouse),
	.ps2_mouse_ext     (ps2_mouse_ext),
	.forced_scandoubler(forced_scandoubler),
	.direct_video      (direct_video),
	.video_rotated     (video_rotated),
	// hps_io's `new_vmode` ("toggle to force notify of video mode change", sys/hps_io.sv:115):
	// any change of the level is compared against the value latched at the previous frame
	// (hps_io.sv:957 `old_vmode != new_vmode`), so a level that flips on every mode switch is a
	// toggle. The guest's 0x09A8 bit 0 moves the raster between 24.8 kHz / 56.4 Hz and
	// 31.5 kHz / 70.1 Hz with the same 640 x 400 active area, which hcnt/vcnt cannot see on the
	// native path; vid_vmode (pc9821_video_out's vmode_31, the video PLL's configuration on
	// clk_vid) makes Main re-take the frame timing on every switch.
	.new_vmode         (vid_vmode),
	.gamma_bus         (gamma_bus),
	.status_in         (status_in),
	.status_set        (status_set),
	.status_menumask   (status_menumask),
	.info_req          (info_req),
	.info              (info),
	.img_mounted       (hps_img_mounted),
	.img_readonly      (hps_img_readonly),
	.img_size          (hps_img_size),
	.sd_lba            (sd_lba),
	.sd_blk_cnt        (sd_blk_cnt),
	.sd_rd             (sd_rd),
	.sd_wr             (sd_wr),
	.sd_ack            (sd_ack),
	.sd_buff_addr      (sd_buff_addr),
	.sd_buff_dout      (sd_buff_dout),
	.sd_buff_din       (sd_buff_din),
	.sd_buff_wr        (sd_buff_wr),
	.ioctl_download    (ioctl_download),
	.ioctl_index       (ioctl_index),
	.ioctl_wr          (ioctl_wr),
	.ioctl_addr        (ioctl_addr),
	.ioctl_dout        (ioctl_dout),
	.ioctl_upload      (ioctl_upload),
	.ioctl_upload_req  (1'b0),
	.ioctl_upload_index(8'd0),
	.ioctl_din         (16'd0),
	.ioctl_rd          (ioctl_rd),
	.ioctl_file_ext    (ioctl_file_ext),
	.ioctl_wait        (ioctl_wait),
	.sdram_sz          (sdram_sz),
	.RTC               (rtc),
	.TIMESTAMP         (timestamp),
	.uart_mode         (uart_mode),
	.uart_speed        (uart_speed),
	.EXT_BUS           (ext_bus)
);

// The CD-DA path's nets (pc9821_atapi -> cdda -> the mixer's CD channel; see CDDA_EN). With
// CDDA_EN 0 the request is tied off below and the write side has no reader.
/* verilator lint_off UNUSEDSIGNAL */
wire        cdda_req;
wire        cdda_req4;
wire        cdda_played;
wire        cdda_flush;
wire        cdda_wr;
wire [31:0] cdda_dout;
/* verilator lint_on UNUSEDSIGNAL */
wire [15:0] cdda_l;
wire [15:0] cdda_r;

// The ext-bus half hps_ext would own is driven with what an idle hps_ext drives for every
// command outside its 0x61-0x63 range: dout_en (EXT_BUS[32]) low, which makes hps_io answer from
// its own io_dout (sys/hps_io.sv: `assign HPS_BUS[15:0] = EXT_BUS[32] ? EXT_BUS[15:0] : ...`), and
// a zero data half. The CD-DA ring is fed by the CD drive (pc9821_atapi) instead.
assign ext_bus[15:0] = 16'd0;
assign ext_bus[32]   = 1'b0;

wire guest_mem_busy;
wire [31:0] guest_mem0_addr;
wire [31:0] guest_mem0_din;
// Port 0's two-word write payload, word 1 (the PEGC store buffer's pair drain).
wire [31:0] guest_mem0_din_hi;
// The G3 gather-RMW session request (the PEGC store buffer's group drain).
wire        guest_mem0_gath;
wire [440:0] guest_mem0_gath_extra;
wire [31:0] guest_mem0_dout;
wire        guest_mem0_resp_valid;
wire  [3:0] guest_mem0_be;
wire  [7:0] guest_mem0_burstcount;
wire        guest_mem0_ready;
wire        guest_mem0_valid;
wire        guest_mem0_write;
wire [31:0] guest_mem1_addr;
wire [31:0] guest_mem1_din;
wire [31:0] guest_mem1_dout;
wire        guest_mem1_resp_valid;
wire  [3:0] guest_mem1_be;
wire  [7:0] guest_mem1_burstcount;
wire        guest_mem1_ready;
wire        guest_mem1_valid;
wire        guest_mem1_write;
// The controller's FOURTH requester: the PEGC packed scanout's line fetch
// (src/pc9821/core/pc9821_pegc_scan.sv).
wire [31:0] guest_mem3_addr;
wire [31:0] guest_mem3_din;
wire [31:0] guest_mem3_dout;
wire        guest_mem3_resp_valid;
wire  [3:0] guest_mem3_be;
wire  [7:0] guest_mem3_burstcount;
wire        guest_mem3_ready;
wire        guest_mem3_valid;
wire        guest_mem3_write;
// The controller's THIRD requester: the 86-PCM sample buffer
// (src/pcm86/pc9821_pcm86_buf.sv).
wire [31:0] guest_mem2_addr;
wire [31:0] guest_mem2_din;
wire [31:0] guest_mem2_dout;
wire        guest_mem2_resp_valid;
wire  [3:0] guest_mem2_be;
wire  [7:0] guest_mem2_burstcount;
wire        guest_mem2_ready;
wire        guest_mem2_valid;
wire        guest_mem2_write;

// The trace's stall context: the CPU's port-0 request, which pc9821_system's ext_mem0_* ports
// carry.
assign trace_ctx_addr       = guest_mem0_addr;
assign trace_ctx_valid      = guest_mem0_valid;
assign trace_ctx_write      = guest_mem0_write;
assign trace_ctx_ready      = guest_mem0_ready;
assign trace_ctx_resp_valid = guest_mem0_resp_valid;

split_sdram_backend #(
	.FREQ(CLOCK_RATE_HZ),   // the controller runs on clk_sys
	.ADQM(1'b1),   // the MiSTer 128MB XSDS wires DQML/DQMH to A11/A12; mask rides a[12:11]
	.GATHER_K(GATHER_K),
	.DQ_IN_DDIO(SDRAM_DQ_DDIO),
	.OUT_DDIO(SDRAM_OUT_DDIO),
	.DBG_CL(SDRAM_DBG_CL),
	.DBG_TRCD_TRP(SDRAM_DBG_TRCD_TRP),
	.FAST_GRADE(1'b0)   // -7 speed grade: matches z486_mister.sdc's Alliance AS4C32M16SB-7 and the ao486 core's target
) de10_guest_memory (
	.clk(clk_sys),
	.reset(reset_sync_r[2]),
	.refresh_allowed(1'b1),
	.sdram_size(sdram_sz[1:0]),
	.busy(guest_mem_busy),
	.mem0_valid(guest_mem0_valid),
	.mem0_ready(guest_mem0_ready),
	.mem0_write(guest_mem0_write),
	.mem0_addr(guest_mem0_addr),
	.mem0_din(guest_mem0_din),
	.mem0_din_hi(guest_mem0_din_hi),
	.mem0_gath(guest_mem0_gath),
	.mem0_gath_extra(guest_mem0_gath_extra),
	.mem0_dout(guest_mem0_dout),
	.mem0_resp_valid(guest_mem0_resp_valid),
	.mem0_be(guest_mem0_be),
	.mem0_burstcount(guest_mem0_burstcount),
	.mem1_valid(guest_mem1_valid),
	.mem1_ready(guest_mem1_ready),
	.mem1_write(guest_mem1_write),
	.mem1_addr(guest_mem1_addr),
	.mem1_din(guest_mem1_din),
	.mem1_dout(guest_mem1_dout),
	.mem1_resp_valid(guest_mem1_resp_valid),
	.mem1_be(guest_mem1_be),
	.mem1_burstcount(guest_mem1_burstcount),
	.mem2_valid(guest_mem2_valid),
	.mem2_ready(guest_mem2_ready),
	.mem2_write(guest_mem2_write),
	.mem2_addr(guest_mem2_addr),
	.mem2_din(guest_mem2_din),
	.mem2_dout(guest_mem2_dout),
	.mem2_resp_valid(guest_mem2_resp_valid),
	.mem2_be(guest_mem2_be),
	.mem2_burstcount(guest_mem2_burstcount),
	.mem3_valid(guest_mem3_valid),
	.mem3_ready(guest_mem3_ready),
	.mem3_write(guest_mem3_write),
	.mem3_addr(guest_mem3_addr),
	.mem3_din(guest_mem3_din),
	.mem3_dout(guest_mem3_dout),
	.mem3_resp_valid(guest_mem3_resp_valid),
	.mem3_be(guest_mem3_be),
	.mem3_burstcount(guest_mem3_burstcount),
	.sdram_dq(SDRAM_DQ),
	.sdram_a(SDRAM_A),
	.sdram_ba(SDRAM_BA),
	.sdram_dqm({SDRAM_DQMH, SDRAM_DQML}),
	.sdram_nwe(SDRAM_nWE),
	.sdram_nras(SDRAM_nRAS),
	.sdram_ncas(SDRAM_nCAS),
	.sdram_ncs(SDRAM_nCS),
	.sdram_cke(SDRAM_CKE)
);

pc9821_system #(
	.SYS_FREQ(CLOCK_RATE_HZ),
	.GATHER_K(GATHER_K),
	.DCACHE_SET_BITS(DCACHE_SET_BITS),
	.ICACHE_SET_BITS(ICACHE_SET_BITS),
	.ENABLE_X87(ENABLE_X87),
	.IO_LATENCY_PROFILE(IO_LATENCY_PROFILE),
	.PERF_LOG_EN(PERF_LOG_EN),
	.MPU_EN(MPU_EN),
	.SDRAM_PHASE_DYN(SDRAM_PHASE_DYN),
	.CDROM_EN(CDROM_EN),
	.CDROM_AUDIO_EN(CDROM_AUDIO_EN),
	.CDROM_LOG_EN(CDROM_LOG_EN),
	.DBG_GDC_EN(DBG_GDC_EN),
	.DBG_CPU_EN(DBG_CPU_EN),
	.DBG_SAMPLE_MS(DBG_SAMPLE_MS),
	.DBG_SNOOP_EN(DBG_SNOOP_EN),
	.DBG_SNOOP_LO(DBG_SNOOP_LO),
	.DBG_SNOOP_HI(DBG_SNOOP_HI),
	.DBG_TRIG_KIND(DBG_TRIG_KIND),
	.DBG_TRIG_ADDR(DBG_TRIG_ADDR),
	.DBG_TRIG_CS(DBG_TRIG_CS),
	.DBG_TRIG2_LO(DBG_TRIG2_LO),
	.DBG_TRIG2_HI(DBG_TRIG2_HI),
	.DBG_ARM_S(DBG_ARM_S),
	.DBG_POST(DBG_POST)
/* verilator lint_off PINMISSING */   // software_reset is the observable port; see the note above
// THE EMPTY CONNECTIONS HERE ARE DELIBERATE: the core's debug and trace monitor outputs are for a
// host-side view this build does not instantiate, and wiring them to wires nothing reads would
// only move the warning to UNUSEDSIGNAL.
/* verilator lint_off PINCONNECTEMPTY */
) core (
	.clk_sys             (clk_sys),
	.reset               (reset_sync_r[2]),
	.hps_apply_reset     (status[0]),
	.rtc                 (rtc[55:0]),
	// The CPU's triple-fault reset is consumed inside pc9821_system (a warm
	// CPU reset through the same class as `out 0xF0`); its monitor output is
	// deliberately left unconnected here -- it must NOT drive BUTTONS[1], because
	// user_io.cpp masks that echo while the OSD is visible.

	.joystick_dis        (joystick_dis),
	.joystick_dig_1      (joystick_dig_1),
	.joystick_dig_2      (joystick_dig_2),
	.joystick_ana_1      (joystick_ana_1),
	.joystick_ana_2      (joystick_ana_2),
	.joystick_mode       (joystick_mode),
	.joystick_timed      (joystick_timed),

	.ext_mem_busy        (guest_mem_busy),
	.sdram_size          (sdram_sz[1:0]),
	.ext_mem0_addr       (guest_mem0_addr),
	.ext_mem0_din        (guest_mem0_din),
	.ext_mem0_din_hi     (guest_mem0_din_hi),
	.ext_mem0_gath       (guest_mem0_gath),
	.ext_mem0_gath_extra (guest_mem0_gath_extra),
	.ext_mem0_dout       (guest_mem0_dout),
	.ext_mem0_resp_valid (guest_mem0_resp_valid),
	.ext_mem0_be         (guest_mem0_be),
	.ext_mem0_burstcount (guest_mem0_burstcount),
	.ext_mem0_ready      (guest_mem0_ready),
	.ext_mem0_valid      (guest_mem0_valid),
	.ext_mem0_write      (guest_mem0_write),
	.ext_mem1_addr       (guest_mem1_addr),
	.ext_mem1_din        (guest_mem1_din),
	.ext_mem1_dout       (guest_mem1_dout),
	.ext_mem1_resp_valid (guest_mem1_resp_valid),
	.ext_mem1_be         (guest_mem1_be),
	.ext_mem1_burstcount (guest_mem1_burstcount),
	.ext_mem1_ready      (guest_mem1_ready),
	.ext_mem1_valid      (guest_mem1_valid),
	.ext_mem1_write      (guest_mem1_write),
	.ext_mem2_addr       (guest_mem2_addr),
	.ext_mem2_din        (guest_mem2_din),
	.ext_mem2_dout       (guest_mem2_dout),
	.ext_mem2_resp_valid (guest_mem2_resp_valid),
	.ext_mem2_be         (guest_mem2_be),
	.ext_mem2_burstcount (guest_mem2_burstcount),
	.ext_mem2_ready      (guest_mem2_ready),
	.ext_mem2_valid      (guest_mem2_valid),
	.ext_mem2_write      (guest_mem2_write),
	.ext_mem3_addr       (guest_mem3_addr),
	.ext_mem3_din        (guest_mem3_din),
	.ext_mem3_dout       (guest_mem3_dout),
	.ext_mem3_resp_valid (guest_mem3_resp_valid),
	.ext_mem3_be         (guest_mem3_be),
	.ext_mem3_burstcount (guest_mem3_burstcount),
	.ext_mem3_ready      (guest_mem3_ready),
	.ext_mem3_valid      (guest_mem3_valid),
	.ext_mem3_write      (guest_mem3_write),

	.ioctl_download      (ioctl_download),
	.ioctl_index         (ioctl_index),
	.ioctl_wr            (ioctl_wr),
	.ioctl_addr          (ioctl_addr),
	.ioctl_dout          (ioctl_dout),
	.ioctl_wait          (ioctl_wait),
	.img_mounted         (img_mounted[0]),
	.fdd_mounted         (img_mounted[1]),
	.fdd_size            (img_size),
	.fdd_lba             (sd_lba[1]),
	.fdd_blk_cnt         (sd_blk_cnt[1]),
	.fdd_rd              (sd_rd[1]),
	.fdd_wr              (sd_wr[1]),
	.fdd_ack             (sd_ack[1]),
	.fdd_buff_din        (sd_buff_din[1]),
	.fdd1_mounted        (img_mounted[2]),
	// The second drive's image slot reads the SAME hps_io img_size/img_readonly registers as
	// the first's (the framework has one of each, valid for the mount that just happened), and
	// pc9821_fdd_media latches each drive's own value at its own mount pulse.
	.fdd1_size           (img_size),
	.fdd1_lba            (sd_lba[2]),
	.fdd1_blk_cnt        (sd_blk_cnt[2]),
	.fdd1_rd             (sd_rd[2]),
	.fdd1_wr             (sd_wr[2]),
	.fdd1_ack            (sd_ack[2]),
	.fdd1_buff_din       (sd_buff_din[2]),
	.cd_mounted          (cd_mounted),
	.cd_size             (img_size),
	.cd_lba              (cd_lba),
	.cd_blk_cnt          (cd_blk_cnt),
	.cd_rd               (cd_rd),
	.cd_ack              (cd_ack),
	.cdda_req            (cdda_req),
	.cdda_req4           (cdda_req4),
	.cdda_played         (cdda_played),
	.cdda_flush          (cdda_flush),
	.cdda_wr             (cdda_wr),
	.cdda_data           (cdda_dout),
	.img_readonly        (img_readonly),
	.img_size            (img_size),
	.img_lba             (sd_lba[0]),
	.img_blk_cnt         (sd_blk_cnt[0]),
	.img_rd              (sd_rd[0]),
	.img_wr              (sd_wr[0]),
	.img_ack             (sd_ack[0]),
	.img_buff_addr       (sd_buff_addr),
	.img_buff_din        (sd_buff_dout),
	.img_buff_dout       (sd_buff_din[0]),
	.img_buff_wr         (sd_buff_wr),

	.ps2_kbclk_in        (ps2_kbd_clk_out),
	.ps2_kbdat_in        (ps2_kbd_data_out),
	.ps2_key             (ps2_key),
	// The bus mouse's host input (pc9821_mouse via pc9821_iobus): the parsed
	// PS/2 packet, not the PS/2 stream - see the ps2_mouse declaration above.
	.ps2_mouse           (ps2_mouse),
	.ps2_kbclk_out       (ps2_kbd_clk_in),
	.ps2_kbdat_out       (ps2_kbd_data_in),
	.kbd_led_status      (ps2_kbd_led_status),

	.dbg_uart_byte       (core_dbg_uart_byte),
	.dbg_uart_we         (core_dbg_uart_we),
	.trace_trig          (core_trace_trig),
	.cpu_dbg_gate_read   (core_dbg_gate_read),
	.cpu_dbg_gate_addr   (core_dbg_gate_addr),
	.cpu_dbg_pf_code     (core_dbg_pf_code),
	.cpu_dbg_pf_addr     (core_dbg_pf_addr),
	.cpu_dbg_eflags      (core_dbg_eflags),
	.cpu_dbg_page_fault  (core_dbg_page_fault),
	.cpu_dbg_walk_pde    (core_dbg_walk_pde),
	.cpu_dbg_walk_pte    (core_dbg_walk_pte),
	.cpu_dbg_cr3         (core_dbg_cr3),
	.cpu_dbg_SP          (core_dbg_SP),
	.cpu_dbg_issue       (core_dbg_issue),
	.cpu_dbg_issue_eip   (core_dbg_issue_eip),
	.dbg_uart_accept     (debug_uart_wdg_accept),
	.sdph_step_req       (sdph_step_req),
	.sdph_step_up        (sdph_step_up),
	.sdph_step_ack       (sdph_step_ack),
	.sdph_fault          (sdph_fault),
   .mpu_uart_tx         (mpu_uart_tx),
	.mpu_present         (uart_midi_mode),
	.ram_size            (configured_ram_size),
	// The pack sits at the MODULE CEILING, not at the selected guest size: the
	// pack is only written during a download and the HPS does not re-send it on an
	// OSD reset, so the base must not move when the guest size does. The guest size
	// follows the OSD on the reset; only the base is module-fixed.
	.ram_size_max        (ram_size_max),
	.bios_setup          (bios_setup),
	.kbd_layout_jis      (kbd_layout_jis),
	// OSD Machine field: status[31:28] selects the port-0xF0 machine-ID strap LUT.
	// Zero (entry 0) is the measured Xe10 strap, so a config-less card is unchanged.
	.bios_set            (status[31:28]),
	// OSD GDC Clock field, decoded by u_osd: port 0x31 bit 7 (0xF3 = 2.5 MHz is entry 0).
	.gdc_clock_5m        (gdc_clock_5m),
	// OSD FDD mode field, decoded by u_osd: 0x00BE bit 2 (entry 0 = Auto, bit 2 clear).
	.fdd_dip_fixed       (fdd_dip_fixed),
	// OSD CD audio volume field, decoded by u_osd: the CD-DA channel's gain code (vol_cd_l/r).
	.cd_volume_code      (cd_volume_code),
	// OSD hardware-switch field (the `P1` DIP Switch page), read straight from its own
	// status bits the way `bios_set` is: it carries the LIST POSITION, not the encoded
	// switch value, because position 0 must be the measured machine here too - pc9821_crtc
	// decodes the position and latches the decoded nibble on rst_n_sys at every machine
	// reset. Keeping the decode at the store is what makes an undriven port mean the
	// captured machine. THE BASE MEMORY (0xA3FEA bits 2:0) is hardcoded to 640 KB inside
	// pc9821_crtc, not wired from a status field.
	.cfg_fdd_mode        (status[42:40]),
	// OSD CPU Speed: the list position (CONF_STR `O[17:14]`), cpu_throttle's speed_sel.
	.cpu_speed_sel       (status[17:14]),

	.video_ce            (core_ce_pixel),
	.video_31k           (core_31k),
	.video_blank_n       (core_de),
	.video_hsync         (core_hs),
	.video_vsync         (core_vs),
	.video_r             (core_r),
	.video_g             (core_g),
	.video_b             (core_b),

	.sample_86_l        (sample_86_l),
	.sample_86_r        (sample_86_r),
	.speaker_out         (speaker_out),
	.vol_master_l        (vol_master_l),
	.vol_master_r        (vol_master_r),
	.vol_voice_l         (vol_voice_l),
	.vol_voice_r         (vol_voice_r),
	.vol_cd_l            (vol_cd_l),
	.vol_cd_r            (vol_cd_r),
	.vol_midi_l          (vol_midi_l),
	.vol_midi_r          (vol_midi_r),
	.vol_line_l          (vol_line_l),
	.vol_line_r          (vol_line_r),
	.vol_spk             (vol_spk),
	.beep_vol            (beep_vol),
	.vol_en              (vol_en),

	.debug_boot_stage    (),
	.debug_sd_error      (),
	.debug_bios_loaded   (core_bios_loaded),
	.debug_first_instruction(core_first_instruction),
	.debug_post_code     (),
	.debug_post_write    (),

	.cpu_pe              (),
	.cpu_vm              (),
	.cpu_cs              (cpu_cs),
	.cpu_eip             (cpu_eip),
	.cpu_cs_base         ()
	);
/* verilator lint_on PINCONNECTEMPTY */
/* verilator lint_on PINMISSING */

// The -86 card's sample bus leaves clk_sys here and the mixer below samples it on CLK_AUDIO (an
// asynchronous 24.576 MHz PLL) whose SDC group is cut from clk_sys, so the crossing is neither
// synchronised nor timed. Crossing it raw lets a CLK_AUDIO edge catch the bus mid-flight and mix
// old and new bits into a value neither sample had -- the audio crackle -- so it crosses on the
// held handshake the CD path already uses (`audio_cdc` in src/soc/cdda.v). L and R change on the
// same clk_sys edge, so they cross together as one 40-bit vector (the bus is 20
// bits per channel since the A-1 fix: the FM+ADPCM+SSG+PCM86 sum is carried WIDE
// and clamped once at the final DAC below).
wire [19:0] sample_86_l_audio;
wire [19:0] sample_86_r_audio;

cdc_vector_handshake_continuous #(.DATA_WIDTH(20*2)) sample_86_cdc (
	.clk_in   (clk_sys),
	.clk_out  (CLK_AUDIO),
	.data_in  ({sample_86_l, sample_86_r}),
	.data_out ({sample_86_l_audio, sample_86_r_audio})
);

synchronizer speaker_out_sync (
	.clk(CLK_AUDIO),
	.in(speaker_out),
	.out(speaker_out_audio)
);

// The speaker's amplitude: one sounding bit is beep_vol * (1 << (10 + status[19:18])).
// beep_vol is the 2-bit software-DIP BEEPER VOLUME at 0x871E bits [3:2] (pc9821_iobus),
// the register ITF SETUP writes. NP2kai scales the beeper amplitude by it LINEARLY with
// 0 = exact mute: io/dipsw.c:44-57 takes (value >> 2) & 3 from a 0x871E write into
// BEEP_VOL, sound/beepg.c:113-114 scales `samp *= vol; samp <<= (10-2)` in the mode-1
// generator the PC-98 defaults to (sound/beepc.c:68 `g_beep.mode = 1`), and
// sound/beepg.c:161-163 generates exactly nothing at vol 0. The ladder here is therefore
// 0/1,024/2,048/3,072 at status[19:18]=0: code 2 - NP2kai's default "Mid" (pccore.c:847)
// - is 2,048, and code 0 is TRUE mute. status[19:18] remains
// UNDECLARED in this core's CONF_STR, so the shift is always 0 (the absolute level
// question is still open) - and the shift is written as the constant 10. vol_spk is the framework's 0..3 speaker volume
// (3 = 0 dB), applied as a right shift, and is hard-wired by pc9821_system.
//
// The value is UNIPOLAR (0 or +A, never -A), so a sounding beep carries a DC
// offset of A/2; that convention is capture-pending.
//
// `beep_vol` is a GUEST register on clk_sys (0x871E, written by ITF SETUP) sampled here on
// CLK_AUDIO with no synchroniser (docs/clock-domains.md, "Quasi-static levels"). It is a
// 2-bit amplitude CODE, not a coherent word with an invalid state: the value changes only
// when the setup utility writes it, the tone itself (`speaker_out`) is the synchronised
// signal above, and a transition can at worst land one CLK_AUDIO sample on a neighbouring
// step. The audible OPNA/-86 samples are not on this path: they cross on the held handshake
// (`sample_86_cdc`).
always @(posedge CLK_AUDIO) begin
	reg [16:0] spk;
	spk <= speaker_out_audio ? ({15'd0, beep_vol} << 10) : 17'd0;
	spk_out <= spk >> ~vol_spk;
end

// CD-DA (Redbook CD audio): pc9821_atapi streams the CD slot's audio sectors when
// cdda_req is asserted; cdda buffers them and resamples to 44.1 kHz. Real CD
// volume (vol_cd) is applied in pc9821_audio_volume below, so the module's own VOLUME is
// left at full scale (matches ao486).

// AUDIO_CE is cdda's own 44.1 kHz sample strobe, and it is deliberately NOT connected: the
// module only ASSIGNS it (src/soc/cdda.v: its port and the two CLK_AUDIO writes - it is never read), and this design
// takes the CD audio from CLK_AUDIO and AUDIO_L/R directly. A missing pin on a module this
// design instantiates is worth a reason even when the reason is 'no consumer'.
generate
if (CDDA_EN) begin : g_cdda
/* verilator lint_off PINMISSING */
cdda #(24576000) cdda_inst
(
	.CLK       (clk_sys),
	.CDDA_REQ  (cdda_req),
	.CDDA_REQ4 (cdda_req4),
	.CDDA_PLAYED(cdda_played),
	.CDDA_FLUSH(cdda_flush),
	.CDDA_WR   (cdda_wr),
	.CDDA_DATA (cdda_dout),
	.VOLUME_L  (4'b1111),
	.VOLUME_R  (4'b1111),
	.CLK_AUDIO (CLK_AUDIO),
	.AUDIO_L   (cdda_l),
	.AUDIO_R   (cdda_r)
);
/* verilator lint_on PINMISSING */
end else begin : g_no_cdda
	// No CD drive (CDDA_EN above): no request, and the CD channel of the mixer below carries 0 -
	// the value an idle cdda's AUDIO_L/R hold, since nothing ever streams a sector into it.
	assign cdda_req    = 1'b0;
	assign cdda_req4   = 1'b0;
	assign cdda_played = 1'b0;
	// and nothing to flush
	/* verilator lint_off UNUSEDSIGNAL */
	wire cdda_flush_unused = cdda_flush;
	/* verilator lint_on UNUSEDSIGNAL */
	assign cdda_l   = 16'd0;
	assign cdda_r   = 16'd0;
end
endgenerate

// pc9821_audio_volume's outputs below are SAMPLE_WIDTH (20) bits, matching
// the wide -86 bus: the master channel is mix_tmp (the WIDE PRE-CLAMP sum)
// scaled by vol_master, and snd86 carries the unclamped card sum to the final
// mix. Master scaling therefore sits BEFORE mix_dry's saturation - the shape
// NP2kai has, where every source is scaled by vol_master/100 before the sum and
// the output clamp (sound/fmboard.c:103-133) - so lowering master pulls an
// over-rail mix back from the clamp instead of attenuating already-clipped
// audio. Scaling the wide sum is that same linear law
// taken on the exact sum (g*(a+b+c) = g*a+g*b+g*c).
wire signed [19:0] master_l;
wire signed [19:0] master_r;
wire signed [19:0] snd86_l;
wire signed [19:0] snd86_r;
/* verilator lint_off UNUSEDSIGNAL */   // the OPL slot's two outputs are 0 - there is no OPL
// chip on a PC-9821; the slot is kept because it is one of pc9821_audio_volume's channels.
wire signed [19:0] opl_l;
wire signed [19:0] opl_r;
/* verilator lint_on UNUSEDSIGNAL */
wire signed [19:0] cd_l;
wire signed [19:0] cd_r;
// FM/MT32 sample inputs to the audio mixer. No MT32 is instantiated in this build, so that
// branch of the mixer has no source and reads nothing; the wires stay so the mixer's ports have a
// landing place rather than being left unconnected.
/* verilator lint_off UNUSEDSIGNAL */
wire signed [19:0] mt32_l;
wire signed [19:0] mt32_r;
/* verilator lint_on UNUSEDSIGNAL */
wire        audio_volume_valid;
// THREE ANCESTOR OPTIONS FOLDED (the undeclared-option fold). Each read
// an OSD field this CONF_STR does not declare, so each is always 0, and each is written as that 0:
//   * status[21:20] "Audio Boost" chose the acompr compressor's output over the dry mix; at 0 the
//     dry mix is what the card plays, and neither compressor (~100 ALMs) is built.
//   * status[25] "MT32 Volume Ctl" chose the line volume for the MT32 slot; at 0 that slot takes
//     vol_midi (and no MT32 is instantiated, so the slot's samples are 0 either way).
//   * status[56] "SB Swap" swapped the -86 card's L/R (below); at 0 it never swapped.
// Re-offering any of them is a CONF_STR entry plus its read restored.
wire [15:0] mix_pre_l = mix_dry_l;
wire [15:0] mix_pre_r = mix_dry_r;
wire  [4:0] vol_mt32_l = vol_midi_l;
wire  [4:0] vol_mt32_r = vol_midi_r;

// The volume inputs below (vol_master/voice/midi/cd, 5 bits each) and vol_en[2:1] are OSD/mixer
// configuration written on clk_sys and consumed on
// CLK_AUDIO with NO synchroniser. That is intentional: it is the standard MiSTer convention for
// OSD settings, which are quasi-static levels, and the worst case is one sample taken mid-change
// - a click, not corruption. The guest-audible bus (sample_86_l/r) crosses on a handshake instead.
// USED = channels 9..6 (master L/R, -86 L/R) and 3..2 (CD L/R): the OPL and MT32 slots have no source
// and their outputs are unread below, so the stage does not multiplex or hold them (10'h3CC).
pc9821_audio_volume #(.NUM_CH(10), .SAMPLE_WIDTH(20), .USED(10'h3CC)) audio_volume_inst (
	.clk(CLK_AUDIO),
	.volumes_in({vol_master_l, vol_master_r,
	             vol_voice_l,  vol_voice_r,
	             vol_midi_l,   vol_midi_r,
	             vol_cd_l,     vol_cd_r,
	             vol_mt32_l,   vol_mt32_r}),
	// The master slot carries mix_tmp, the wide pre-clamp sum, so master scaling
	// happens before the final saturation. The remaining
	// 16-bit sources sign-extend to the 20-bit fields (the flat concat form:
	// nested per-element braces are a parse trap).
	.samples_in({mix_tmp_l,                mix_tmp_r,
	             sample_86_l_audio,       sample_86_r_audio,
	             20'd0,                   20'd0,
	             {4{cdda_l[15]}},         cdda_l,        {4{cdda_r[15]}},         cdda_r,
	             20'd0,                   20'd0}),
	.samples_out({master_l, master_r,
	              snd86_l,  snd86_r,
	              opl_l,    opl_r,
	              cd_l,     cd_r,
	              mt32_l,   mt32_r}),
	.valid(audio_volume_valid)
);

wire signed [19:0] snd86_l_swap = snd86_l;   // status[56] "SB Swap": undeclared, folded (above)
wire signed [19:0] snd86_r_swap = snd86_r;

always @(posedge CLK_AUDIO) begin
	if (audio_volume_valid) begin
		// THE FINAL DAC: the three sources sum WIDE
		// (20 bits, no wrap possible) into mix_tmp, the master channel scales
		// that sum on its next pass, and the ONE saturation below lands on the
		// SCALED value - master sits before the clamp (NP2kai
		// sound/fmboard.c:103-133), symmetrically at the 16-bit rails
		// (ymfm's clamp16 / NP2kai's _saturation_s16 junction).
		mix_tmp_l <= $signed({3'b0, spk_out})
		           + snd86_l_swap
		           + (vol_en[2] ? cd_l : 20'sd0);
		mix_tmp_r <= $signed({3'b0, spk_out})
		           + snd86_r_swap
		           + (vol_en[1] ? cd_r : 20'sd0);

		mix_dry_l <= (master_l >  20'sd32767) ? 16'h7FFF :
		             (master_l < -20'sd32768) ? 16'h8000 : master_l[15:0];
		mix_dry_r <= (master_r >  20'sd32767) ? 16'h7FFF :
		             (master_r < -20'sd32768) ? 16'h8000 : master_r[15:0];
	end
end

// THE 48 kHz OUTPUT STAGE. Everything above this line is the shipped mix: the ten-channel
// volume mixer, the wide pre-clamp sum and the single saturation at mix_dry (the ancestor's optional
// compressor is folded away). What changes here is only the RATE at which the framework is handed that mix.
//
// Loading core_audio_l_r on audio_volume_valid - one register write per 10 CLK_AUDIO
// cycles - would give a 2.4576 MHz zero-order-hold staircase of the sources' own sample
// instants (55 467 Hz for the OPNA's DAC, 44 100 Hz for PCM86/CD-DA). sys/audio_out.sv
// SAMPLES that register at 48 kHz (its own DAC rate: AUDIO_RATE = 48000, one value per
// sample_ce) and its IIR is a +5 dB shaper, not an anti-alias filter (measured: -0.72 dB at
// 24 kHz, -16.3 dB at 45.5 kHz). Point-sampling the staircase folds its zero-order-hold
// images straight into the audible band: a 10 kHz FM tone puts its 45 467 Hz image at
// 2 533 Hz, measured at -13.2 dB relative to the tone.
//
// pc9821_audio_out is the decimator, ratio 2 457 600/48 000 = 256/5 in three
// stages (CIC decimate-by-4, FIR decimate-by-2, 5/32 polyphase FIR), and it presents exactly
// one new sample per 512 CLK_AUDIO cycles. Measured with it in place: the same 45 467 Hz
// image lands at -66.2 dB (bench tb_pc9821_audio_out_alias measures the folded image against
// a bare latch in the same run: -0.5 dB bare, <= -60 dB here).
//
// The authentic OPNA-side junction is untouched: this block takes the shipped mix_pre
// (post single-clamp) and adds nothing upstream of it - the clamp at jt08_acc,
// the six-drum 16-bit wrap, the SSG's separate analog path with its zero-mean series-cap join
// and the psg * 33/16 balance all sit upstream.
pc9821_audio_out u_audio_out (
	.clk    (CLK_AUDIO),
	.valid  (audio_volume_valid),
	.in_l   (mix_pre_l),
	.in_r   (mix_pre_r),
	.out_l  (core_audio_l),
	.out_r  (core_audio_r)
);

// The instruction trace: one ring entry per EIP transition, dumped over the same debug UART the
// watchdog uses, once the CPU stops moving. The buffer is M10K and the added LAB logic is a small
// FSM, which is why it is affordable at all - this design has memory to spare and not logic.
//
// COMPILED OUT, NOT DISABLED, when TRACE_EN is 0: the instance below does not exist, so the
// shipped netlist has no trace and no extra block RAM.
generate
if (TRACE_EN) begin : g_trace
	pc9821_trace #(
		.AW(13),
		.STALL_CYCLES(CLOCK_RATE_HZ / 5),   // 200 ms, the same window the watchdog calls a stall
		.ARM_RECORDS(64)
	) u_trace (
		.clk(clk_sys), .reset(reset_sync_r[2]),
		.cs(cpu_cs), .eip(cpu_eip),
		.ctx_addr(trace_ctx_addr), .ctx_write(trace_ctx_write),
		.ctx_valid(trace_ctx_valid), .ctx_ready(trace_ctx_ready),
		.ctx_resp_valid(trace_ctx_resp_valid),
		// The font port is the SAME wire the SDRAM controller is driven with - ext_mem1_valid is
		// fmem_valid - so this is a tap on an existing signal and not a second copy of it.
		.ctx_fmem_valid(guest_mem1_valid),
		.trig(core_trace_trig),
		.out_ready(debug_uart_fifo_count != 10'd512 && !debug_uart_banner_active),
		.out_byte(trace_byte), .out_we(trace_we)
	);
end else begin : g_no_trace
	assign trace_byte = 8'd0;
	assign trace_we   = 1'b0;
end
endgenerate

always @(*) begin
	debug_uart_enqueue = 1'b0;
	debug_uart_dequeue = 1'b0;

	// THE TRACE SHARES THIS FIFO WITH THE WATCHDOG, and both must be able to get a byte in: the
	// watchdog message is what says a stall happened at all, so dropping it to make room for the
	// trace would hide the thing the trace explains. The trace is lower priority than the banner
	// and higher than the watchdog, and it only emits when there is room, so neither is starved;
	// the two interleave in the capture and the decoders separate them by shape.
	// A watchdog byte that cannot get in here is NOT dropped: debug_uart_wdg_accept above is this
	// chain's own answer for that source, and pc9821_dbg_record holds the byte until it is set
	// so the 289+232+100-byte report survives a full FIFO however long the drain takes.
	if (debug_uart_banner_active && debug_uart_fifo_count != 10'd512)
		debug_uart_enqueue = 1'b1;
	else if (trace_we && debug_uart_fifo_count != 10'd512)
		debug_uart_enqueue = 1'b1;
	else if (core_dbg_uart_we && debug_uart_fifo_count != 10'd512)
		debug_uart_enqueue = 1'b1;

	if (!debug_uart_busy && !debug_uart_wr && debug_uart_fifo_count != 10'd0)
		debug_uart_dequeue = 1'b1;
end

always @(posedge clk_sys) begin
	if (reset_sync_r[2]) begin
		debug_uart_data <= 8'd0;
		debug_uart_wr <= 1'b0;
		debug_uart_fifo_wr <= 9'd0;
		debug_uart_fifo_rd <= 9'd0;
		debug_uart_fifo_count <= 10'd0;
		debug_uart_banner_active <= 1'b0;
		debug_uart_banner_index <= 5'd0;
		debug_uart_reset_d <= 1'b1;
	end else begin
		debug_uart_wr <= 1'b0;
		debug_uart_reset_d <= 1'b0;

		if (debug_uart_reset_d) begin
			debug_uart_banner_active <= 1'b1;
			debug_uart_banner_index <= 5'd0;
		end

		if (debug_uart_dequeue) begin
			// THE FIFO's STORAGE IS NEEDED ONLY WHEN SOMETHING BESIDES THE BANNER CAN ENQUEUE. With
			// TRACE_EN and PERF_LOG_EN both 0, trace_we is the constant 0 (g_no_trace below) and
			// pc9821_system ties dbg_uart_we off (its g_telemetry section does not exist), so the only
			// source is the reset banner, enqueued from index 0 after every reset - which also zeroes
			// both pointers - and the byte at read pointer rd is always debug_banner_char(rd). The
			// constant condition picks that table in the shipped profiles (the memory then has no
			// reader and is removed) and reads the FIFO in the trace/perf-log builds; the pointers,
			// the count and the handshake are the same either way, so the UART sends the same
			// bytes on the same clocks.
			// DBG_UART_EN (the CD drive's command log and the debug instruments) is the third such source,
			// on the same arm as the telemetry. Left out of this condition, every log byte would go out as the
			// banner character at that read pointer: a "Z386 start" and 21 LFs repeating at the log's
			// byte rate.
			debug_uart_data <= (TRACE_EN || PERF_LOG_EN || DBG_UART_EN) ? debug_uart_fifo[debug_uart_fifo_rd]
			                                             : debug_banner_char(debug_uart_fifo_rd[4:0]);
			debug_uart_fifo_rd <= debug_uart_fifo_rd + 9'd1;
			debug_uart_wr <= 1'b1;
		end

		if (debug_uart_enqueue) begin
			debug_uart_fifo[debug_uart_fifo_wr] <= debug_uart_banner_active ? debug_banner_char(debug_uart_banner_index) :
			                                       trace_we ? trace_byte : core_dbg_uart_byte;
			debug_uart_fifo_wr <= debug_uart_fifo_wr + 9'd1;
			if (debug_uart_banner_active) begin
				if (debug_uart_banner_index == 5'd11)
					debug_uart_banner_active <= 1'b0;
				debug_uart_banner_index <= debug_uart_banner_index + 5'd1;
			end
		end

		case ({debug_uart_enqueue, debug_uart_dequeue})
			2'b10: debug_uart_fifo_count <= debug_uart_fifo_count + 9'd1;
			2'b01: debug_uart_fifo_count <= debug_uart_fifo_count - 9'd1;
			default: debug_uart_fifo_count <= debug_uart_fifo_count;
		endcase
	end
end

uart_tx_V2 debug_uart_tx_i
(
	.clk                (clk_sys),
	.din                (debug_uart_data),
	.wr_en              (debug_uart_wr),
	.tx_busy            (debug_uart_busy),
	.tx_p               (debug_uart_tx)
);
// defparam is deprecated in IEEE 1800-2023, but both toolchains support it and the override is
// exact. Converting these two to a parameter list on the instance changes an instantiation in the
// deployable top for no functional gain, so it is waived here and reported as a candidate rather
// than done in a warning triage.
/* verilator lint_off DEFPARAM */
defparam debug_uart_tx_i.clk_freq = CLOCK_RATE_HZ;
defparam debug_uart_tx_i.uart_freq = 115200;
/* verilator lint_on DEFPARAM */

// Video out follows developer/emu.md's requirement that the video clock exceed 40 MHz and that
// CE_PIXEL derive from CLK_VIDEO: CLK_VIDEO = clk_vid, the video PLL's exact multiple of the dot rate
// (42.105 MHz), and CE_PIXEL is a constant whole number of its clocks (pc9821_video_out). A
// fractional 21.05 MHz enable on clk_sys would make every pixel and sync edge jitter by a clk_sys
// period on the analog port.
// The framework's video_cleaner as this chain uses it - the two sync-polarity fixers and one ce_pix
// register stage - with the fixers' 32-bit counters replaced by CLOCK_RATE_HZ/16-clock saturating
// ones (src/pc9821/video/pc9821_video_cleaner.sv says why that is output-identical for every sync
// the GDC can program; tb_pc9821_video_cleaner_equiv runs it against sys/video_cleaner.sv).
// Blanking is carried by DE (h_active && v_active), never by the upstream module's VGA_DE /
// HBlank_out / VBlank_out, whose HBlank/VBlank/interlace/f1 inputs this core tied to 0, so the
// copy has neither. NOTE: video_hsync is ~in_hsync, i.e. LOW during the sync pulse and HIGH
// through the active period -- it is not a blanking signal.
// ==== THE ANALOG CONVERTER (VIDEO_DBL_EN) ====
// The core's one picture feeds both the HDMI scaler and the analog port (sys_top), so a converter
// that is running changes what the scaler receives as well: the doubled picture is the same image
// at 640x800. Native (position 0) sends the GDC's raster unchanged.
// THE OSD FIELD "Analog video", status[81:80]: 0 native, 1 the doubler, exactly as CONF_STR_VIDEO
// lists them. MiSTer.ini's forced_scandoubler=1 is a user's statement that the analog monitor needs
// a scan-doubled signal, so with the doubler built it turns doubling on while the field is at Native.
localparam [1:0] VIDEO_SEL_DBL = 2'd1;
wire [1:0] video_sel = status[81:80];
/* verilator lint_off UNUSEDSIGNAL */   // unread in a build without the doubler
wire       video_dbl_on = VIDEO_DBL_EN && (video_sel == VIDEO_SEL_DBL || (video_sel == 2'd0 && forced_scandoubler));
/* verilator lint_on UNUSEDSIGNAL */
// THE VIDEO PLL: a fractional-N PLL, 50 MHz x (M + K/2^32) / 19, generated by build_profile.py from
// tools/profile/vpll_template.v into rtl/vpll* at its FASTEST run-time configuration (the 31 kHz
// clock) and read back exact. pc9821_vpll_ctl moves it to the 24 kHz configuration after lock and
// to the 31 kHz one whenever the guest sets 0x09A8 bit 0 (pc9821_vclk_pkg). The reconfiguration core runs on the 50 MHz
// reference, as the framework's pll_cfg_hdmi does.
wire       vpll_locked;
wire       vclk_31;          // the video PLL is (going to) the 31 kHz configuration
wire       vclk_busy;        // the video clock is not usable: pc9821_video_out flushes its FIFO
wire [63:0] vpll_to_pll, vpll_from_pll;
wire        vcfg_waitrequest, vcfg_write;
wire  [5:0] vcfg_address;
wire [31:0] vcfg_writedata;
vpll vpll (
	.refclk(CLK_50M), .rst(1'b0), .outclk_0(clk_vid), .locked(vpll_locked),
	.reconfig_to_pll(vpll_to_pll), .reconfig_from_pll(vpll_from_pll)
);
// The framework's write-only reconfiguration core (sys/pll_cfg/pll_cfg_hdmi.v), the same module
// sys_top drives the HDMI PLL with. pc9821_vpll_ctl writes only N (0x03), M (0x04), K (0x07) and
// start (0x02), which are exactly this core's N_REG/M_REG/DSM_REG/START_REG, and nothing in the
// tree reads the core's status registers, so the full pll_cfg core's read/MIF/DPS arms and its
// C0..C17 counter file are dead weight here. The fit's entity table prices the two at
// 410 ALMs / 296 regs (pll_cfg:vpll_cfg) against 170 / 192 (pll_cfg_hdmi, one fit);
// tb_pc9821_pll_cfg_lockstep drives both with the same controller and proves the two
// cores program a PLL register model with the same sequence and the same final registers.
pll_cfg_hdmi vpll_cfg (
	.mgmt_clk(CLK_50M), .mgmt_reset(1'b0),
	.mgmt_waitrequest(vcfg_waitrequest),
	.mgmt_write(vcfg_write), .mgmt_address(vcfg_address), .mgmt_writedata(vcfg_writedata),
	.reconfig_to_pll(vpll_to_pll), .reconfig_from_pll(vpll_from_pll)
);
pc9821_vpll_ctl vpll_ctl (
	.clk(CLK_50M), .want_31k(core_31k), .pll_locked(vpll_locked),
	.mgmt_waitrequest(vcfg_waitrequest), .mgmt_write(vcfg_write),
	.mgmt_address(vcfg_address), .mgmt_writedata(vcfg_writedata),
	.vclk_31(vclk_31), .busy(vclk_busy)
);

wire       dbl_active;
wire       vid_fifo_ev;
/* verilator lint_off PINCONNECTEMPTY */   // clk_video: clk_vid itself, used directly below
pc9821_video_out #(.DBL_EN(VIDEO_DBL_EN)) video_out (
	.clk_sys(clk_sys), .ce(core_ce_pixel),
	.r_in(core_r), .g_in(core_g), .b_in(core_b), .hs_in(core_hs), .vs_in(core_vs), .de_in(core_de),
	.dbl_on(video_dbl_on),
	.clk_vid(clk_vid), .vclk_31(vclk_31), .vid_rst(vclk_busy),
	.clk_video(),
	.ce_out(vid_ce), .r_out(vid_r), .g_out(vid_g), .b_out(vid_b), .hs_out(vid_hs), .vs_out(vid_vs), .de_out(vid_de),
	.dbl_active(dbl_active), .vmode_31(vid_vmode), .fifo_ev(vid_fifo_ev)
);
/* verilator lint_on PINCONNECTEMPTY */

// A DIAGNOSTIC: VIDEO_MON_EN builds the on-chip monitor of the analog picture (pc9821_video_mon),
// which owns the UART pin and prints one record a second. Off in every build; set it by hand only
// on a scratch branch for a measurement run.
localparam VIDEO_MON_EN = 1'b0;
wire       video_mon_tx;
generate if (VIDEO_MON_EN) begin : g_video_mon
	pc9821_video_mon #(.VCLK_HZ(VIDEO_CLK_HZ), .SYS_HZ(CLOCK_RATE_HZ)) video_mon (
		.clk_vid(clk_vid), .ce(vid_ce), .hs(vid_hs), .vs(vid_vs), .de(vid_de), .fifo_ev(vid_fifo_ev),
		.clk_sys(clk_sys), .tx(video_mon_tx)
	);
end else begin : g_no_video_mon
	assign video_mon_tx = 1'b1;
	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_mon = vid_fifo_ev;
	/* verilator lint_on UNUSEDSIGNAL */
end endgenerate

pc9821_video_cleaner #(.CLOCK_RATE_HZ(VIDEO_CLK_HZ)) video_cleaner
(
	.clk_vid            (clk_vid),
	.ce_pix             (vid_ce),
	.R                  (vid_r),
	.G                  (vid_g),
	.B                  (vid_b),
	.HSync              (vid_hs),
	.VSync              (vid_vs),
	.DE_in              (vid_de),
	.VGA_R              (clean_r),
	.VGA_G              (clean_g),
	.VGA_B              (clean_b),
	.VGA_VS             (clean_vs),
	.VGA_HS             (clean_hs),
	.DE_out             (clean_de)
);

/* verilator lint_off PINMISSING */   // HBlank_out/VBlank_out unused: blanking is carried by DE
gamma_fast gamma
(
	.clk_vid            (clk_vid),
	.ce_pix             (vid_ce),

	.gamma_bus          (gamma_bus),

	.HSync              (clean_hs),
	.VSync              (clean_vs),
	.DE                 (clean_de),
	// Tied for the same reason as video_cleaner's, whose section is immediately
	// above: gamma_fast drives HBlank_out/VBlank_out straight from these two
	// inputs, so undriven they read x in simulation and 0 on the card. Neither
	// output is connected here -- this chain carries blanking in DE -- so
	// nothing is broken, but tying the inputs keeps them defined.
	.HBlank             (1'b0),
	.VBlank             (1'b0),
	.RGB_in             ({clean_r, clean_g, clean_b}),

	.HSync_out          (gamma_hs),
	.VSync_out          (gamma_vs),
	.DE_out             (gamma_de),
	.RGB_out            ({gamma_r, gamma_g, gamma_b})
);
/* verilator lint_on PINMISSING */

// OSD "Aspect ratio" (status[23:22]) and "Scale" (status[46:45]). The first
// drives video_freak's ARX/ARY: option 0 is 4:3, option 1 ("full screen") is
// the freescale sentinel 3:0, and options 2/3 are the arc1/arc2 values the
// framework substitutes for them (sys_top.v rewrites ARX==1/2 from the custom
// ratios the OSD's [ARC1]/[ARC2] labels name). "Full screen" must be 3:0, not
// 0:0: video_freak only pass-throughs the x:0 encodings (its guard reads
// `!SCALE || (!ary_i && arx_i)`, and 0:0 fails the second arm), so 0:0 with a
// non-zero Scale falls into the integer-scaling FSM, whose `if(!ary_i)` jump
// skips the states that load its aspect target and leaves state 12 computing
// from a stale one. Any non-zero x:0 passes through both Scale paths unchanged,
// and sys_top maps ARY==0 with ARX other than 1/2 to 0:0 - its freescale
// encoding (`FREESCALE || !arx || !ary`) - so 3:0 is full screen with every
// Scale value. The second drives video_freak's SCALE and is the integer-scaling
// control: 0 leaves the picture alone, 1..3 ask video_freak for a V-integer or
// HV-integer output size, which it publishes as ARX/ARY with bit 12 set.
reg  [2:0] ar;
reg  [2:0] scale;
reg [11:0] arx_i;
reg [11:0] ary_i;
// ar and scale are 3 bits to match what video_freak's option fields expect, and the OSD fields
// feeding them are 2 bits, so bit 2 zero-extends: the reachable values are 0..3, which is what
// the comment above describes (1..3 select a size, 0 leaves the picture alone). The subtraction
// sits in a 12-bit context because its result goes to arx_i, so `ar` zero-extends there too - and
// ar is at least 2 on that arm (only the ARC1/ARC2 options use it), so the result is exact.
/* verilator lint_off WIDTHEXPAND */
always @(posedge clk_vid) begin
	ar    <= status[23:22];
	scale <= status[46:45];
	arx_i <= (ar == 3'd0) ? 12'd4 : (ar == 3'd1) ? 12'd3 : (ar - 1'd1);
	ary_i <= (ar == 3'd0) ? 12'd3 : 12'd0;
end
/* verilator lint_on WIDTHEXPAND */

video_freak video_freak
(
	.CLK_VIDEO          (clk_vid),
	.CE_PIXEL           (vid_ce),
	.VGA_VS             (gamma_vs),
	.HDMI_WIDTH         (HDMI_WIDTH),
	.HDMI_HEIGHT        (HDMI_HEIGHT),
	// VGA_DE is deliberately not used: video_freak's DE output is a crop mask,
	// and with CROP_SIZE tied to 0 below its VGA_DE is VGA_DE_IN unchanged, so
	// the top takes the picture's DE from the cleaner/gamma chain instead. If
	// cropping is ever enabled, this must become the DE source.
	/* verilator lint_off PINCONNECTEMPTY */   // reason is the note directly above
	.VGA_DE             (),
	/* verilator lint_on PINCONNECTEMPTY */
	.VIDEO_ARX          (arx),
	.VIDEO_ARY          (ary),
	.VGA_DE_IN          (gamma_de),
	.ARX                (arx_i),
	.ARY                (ary_i),
	.CROP_SIZE          (12'd0),
	.CROP_OFF           (5'd0),
	.SCALE              (scale)
);

assign CLK_VIDEO     = clk_vid;
assign CE_PIXEL      = vid_ce;
assign VIDEO_ARX     = arx;
assign VIDEO_ARY     = ary;
assign VGA_R         = gamma_r;
assign VGA_G         = gamma_g;
assign VGA_B         = gamma_b;
assign VGA_HS        = gamma_hs;
assign VGA_VS        = gamma_vs;
assign VGA_DE        = gamma_de;
assign VGA_F1        = 1'b0;
// The framework's scanline darkener (sys/scanlines.v, on the analog AND the scaler input) dims every
// other line: meaningful on the doubled picture only, so the OSD's "Scanlines" field (status[83:82],
// built with the doubler) reaches it only while the doubler is running.
assign VGA_SL        = (VIDEO_DBL_EN && dbl_active) ? status[83:82] : 2'b00;
// VGA_SCALER would put the scaler's output on the analog port (sys_top: `vga_scaler = cfg[2] |
// vga_force_scaler`, and `vga_fb = cfg[12] | vga_force_scaler`, which only re-selects the HDMI
// clock/direct-video mux and the analog source; the ascal's framebuffer and palette are FB_EN's,
// which this core ties off). It stays 0, as the upstream template has it: the analog port carries
// the core's own signal, and a user who wants the scaler there sets MiSTer.ini vga_scaler=1.
assign VGA_SCALER    = 1'b0;
assign VGA_DISABLE   = 1'b0;
assign HDMI_FREEZE   = 1'b0;
assign HDMI_BLACKOUT = 1'b0;
assign HDMI_BOB_DEINT = 1'b0;
`ifdef MISTER_FB
// There is no guest-visible DDR framebuffer to describe. This core drives its own RGB through
// video_mixer and the scaler. The framework's pins exist because z486_mister.qsf sets MISTER_FB
// and sys_top connects them, so they are tied to the no-framebuffer values.
assign FB_EN          = 1'b0;
assign FB_FORMAT      = 5'd0;
assign FB_WIDTH       = 12'd0;
assign FB_HEIGHT      = 12'd0;
assign FB_BASE        = 32'd0;
assign FB_STRIDE      = 14'd0;
assign FB_FORCE_BLANK = 1'b0;
`ifdef MISTER_FB_PALETTE
assign FB_PAL_CLK    = clk_sys;
assign FB_PAL_ADDR   = 8'd0;
assign FB_PAL_DOUT   = 24'd0;
assign FB_PAL_WR     = 1'b0;
`endif
`endif

assign LED_USER      = pll_locked;
assign LED_POWER     = {1'b1, core_bios_loaded};
assign LED_DISK      = {1'b1, core_first_instruction};
// The framework's BUTTONS output simulates I/O-board button presses (b[1]
// user button, b[0] osd button, MkDocs_MiSTer emu.md). This core has no button
// to simulate: the CPU's triple-fault reset is a local warm reset, so BUTTONS
// is tied off rather than driven from it.
assign BUTTONS       = 2'b00;

// The framework's audio contract (sys/emu_ports.vh:78-86), answered here:
//   * AUDIO_S is the SIGNEDNESS flag, not a sample strobe: 1 is two's complement, which is what
//     mix_dry's symmetric saturation emits (sys/audio_out.sv:217 converts on that basis).
//   * There is no strobe port and no framework FIFO. The framework's substitute for a strobe is
//     that it latches core_l/r only when two consecutive CLK_AUDIO edges agree
//     (sys/audio_out.sv:166-171); these two registers load once per audio_volume_valid, every 10
//     CLK_AUDIO cycles, so the port is stable five times longer than that rule asks.
//   * The crossing into CLK_AUDIO is the core's own job: sys/sys_top.sdc puts pll_audio in an
//     exclusive clock group and false-paths AUDIO_L/R (:30-31), so the framework never times it.
assign AUDIO_L       = core_audio_l;
assign AUDIO_R       = core_audio_r;
assign AUDIO_S       = 1'b1;
// AUDIO_MIX is the framework's stereo->mono crossfeed depth (0 none, 1 25%, 2 50%, 3 mono;
// sys/emu_ports.vh:86, applied at sys/audio_out.sv:330-340). status[44:43] is the reference core's
// "Stereo Mix" field (ao486.sv:80,987), but this CONF_STR declares no option on those bits, so the
// field is hard-wired 0 = "no mix" - a legal value, and the one PC88_MiSTer and NES_MiSTer drive
// literally. Declaring the option is how it becomes reachable.
// The field is written as that constant (sys_top's aud_mix_top pair then
// folds its crossfeed arms away).
assign AUDIO_MIX     = 2'd0;

assign ADC_BUS       = 4'bzzzz;

assign SD_SCK        = 1'bz;
assign SD_MOSI       = 1'bz;
assign SD_CS         = 1'bz;

// There is no HPS DDR window consumer in this core (no framebuffer, no loader): the DDRAM_* bus
// is idle.
assign DDRAM_CLK     = clk_sys;
assign DDRAM_BURSTCNT = 8'd0;
assign DDRAM_ADDR    = 29'd0;
assign DDRAM_RD      = 1'b0;
assign DDRAM_DIN     = 64'd0;
assign DDRAM_BE      = 8'd0;
assign DDRAM_WE      = 1'b0;
generate if (SDRAM_CLK_DDIO) begin : sdram_clk_ddio
// SDRAM_CLK = inverted clk_sys through an output DDIO (datain_h=0, datain_l=1), the way
// Template_MiSTer sys_top.v drives HDMI_TX_CLK. PLL output 1 (clk_sdram_pin) is then spare.
altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdram_clk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk_sys),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);
end else begin : sdram_clk_pll
assign SDRAM_CLK     = clk_sdram_pin;
end endgenerate


assign UART_RTS      = 1'b0;
// THE UART LINE BY OSD MODE (user_io.cpp SetUARTMode `spi_w((mode == 4 || mode == 5) ? 1 : mode);`,
// menu.cpp config_uart_msg[] = None, PPP, Console, MIDI, Modem): MIDI (3) carries the MPU-PC98II's
// TX; None (0, the default, and the only mode a build without the UART page can be in) carries the
// debug UART (the reset banner and any instrument records); PPP/Modem (1) and Console (2) hand the
// line to a Linux process (pppd, the modem emulator, a getty), so it idles high (mark) there and no
// debug byte is typed into it.
wire uart_debug_mode = (uart_mode == 8'd0);
assign UART_TXD      = VIDEO_MON_EN ? video_mon_tx :
                       uart_midi_mode ? mpu_uart_tx :
                       uart_debug_mode ? debug_uart_tx : 1'b1;
assign UART_DTR      = 1'b0;

// The user port has no device in this core, and there is no MIDI source, so
// USER_OUT is an explicit tie-off rather than left undriven.
assign USER_OUT      = 7'd0;

endmodule
