// Native z486 PC-9821 platform: the CPU, the I/O fabric, the memory subsystem, the
// video path, the audio path and the debug telemetry. Per-peripheral status is in
// docs/pc9821-port-status.md.
`default_nettype none

// The vendored z486 memory-map template's PC-98 preset, spliced into the CPU's
// parameter list below. It is included HERE because the macro has to be visible in
// the file that does the instantiation, not in z486.sv.
`include "z486_pc98_preset.svh"

module pc9821_system (
    input         clk_sys,
    input         reset,
    input         hps_apply_reset,
    // Framework RTC in BCD: sec, min, hour, day, month, year, weekday.
    input  [55:0] rtc,
    // The CPU's triple-fault reset request (z486's SHUTDOWN indication). It is
    // consumed LOCALLY -- pc9821_iobus turns it into the machine's CPU-reset
    // class and pc9821_cpu_reset_gate turns that into the reset hold -- so this
    // port is the observable, not a platform action.
    output        software_reset,

	input   [1:0] joystick_dis,
	input  [13:0] joystick_dig_1,
	input  [13:0] joystick_dig_2,
	input  [15:0] joystick_ana_1,
	input  [15:0] joystick_ana_2,
	input   [1:0] joystick_mode,
	input   [1:0] joystick_timed,

    // Vendor-neutral guest-memory backend. KV260 maps both requesters into its
    // unified DDR master; the DE10-Nano wrapper maps them to physical SDRAM.
    // sdram_size is the module geometry the controller sees (1/2/3 = 32/64/128
    // MB); the store buffer groups its gather sessions by the physical row it
    // decides, so it travels down with the backend bus.
    input   [1:0] sdram_size,
    input         ext_mem_busy,
    output [31:0] ext_mem0_addr,
    output [31:0] ext_mem0_din,
    // Port 0's two-word write payload, word 1 (the PEGC store buffer's pair drain;
    // split_sdram_backend carries it to the controller's din0_hi).
    output [31:0] ext_mem0_din_hi,
    // The G3 gather-RMW session request (the PEGC store buffer's group drain;
    // split_sdram_backend carries it to the controller's gath0/gath0_extra).
    output        ext_mem0_gath,
    output [440:0] ext_mem0_gath_extra,
    input  [31:0] ext_mem0_dout,
    input         ext_mem0_resp_valid,
    output  [3:0] ext_mem0_be,
    output  [7:0] ext_mem0_burstcount,
    input         ext_mem0_ready,
    output        ext_mem0_valid,
    output        ext_mem0_write,
    output [31:0] ext_mem1_addr,
    output [31:0] ext_mem1_din,
    input  [31:0] ext_mem1_dout,
    input         ext_mem1_resp_valid,
    output  [3:0] ext_mem1_be,
    output  [7:0] ext_mem1_burstcount,
    input         ext_mem1_ready,
    output        ext_mem1_valid,
    output        ext_mem1_write,

    // The controller's THIRD requester, owned by the 86-PCM sample buffer. It was tied off
    // until the buffer moved out of 32 M10K blocks (src/pcm86/pc9821_pcm86_buf.sv).
    output [31:0] ext_mem2_addr,
    output [31:0] ext_mem2_din,
    input  [31:0] ext_mem2_dout,
    input         ext_mem2_resp_valid,
    output  [3:0] ext_mem2_be,
    output  [7:0] ext_mem2_burstcount,
    input         ext_mem2_ready,
    output        ext_mem2_valid,
    output        ext_mem2_write,
    // The PEGC packed scanout's line fetch: the SDRAM's FOURTH requester (row 6).
    output [31:0] ext_mem3_addr,
    output [31:0] ext_mem3_din,
    input  [31:0] ext_mem3_dout,
    input         ext_mem3_resp_valid,
    output  [3:0] ext_mem3_be,
    output  [7:0] ext_mem3_burstcount,
    input         ext_mem3_ready,
    output        ext_mem3_valid,
    output        ext_mem3_write,

    // NOTE: there is deliberately no video clock input. The PC-98 dot rate (400/19 MHz,
    // 24 kHz text mode) is an enable on clk_sys, exported as video_ce with the picture; the top
    // level carries it into the video clock domain (pc9821_video_out). See pixel_ce below.

    // MiSTer HPS-side boot/media path
    input         ioctl_download,
    input  [15:0] ioctl_index,
    input         ioctl_wr,
    input  [26:0] ioctl_addr,
    input  [15:0] ioctl_dout,
    output        ioctl_wait,
    // A firmware-pack download is being taken under the OSD Reset level
    // (pc9821_memory_subsystem's pack-download hold); z486_mister.sv keeps the SDRAM backend out
    // of the platform reset while it is high.
    output        pack_load_hold,
    input         img_mounted,
    input         img_readonly,
    input  [63:0] img_size,
    output [31:0] img_lba,
    output  [5:0] img_blk_cnt,
    output        img_rd,
    output        img_wr,
    input         img_ack,
    input  [12:0] img_buff_addr,
    input  [15:0] img_buff_din,
    output [15:0] img_buff_dout,
    input         img_buff_wr,
    // The FLOPPY image slots (FDD0 = hps_io slot 1, FDD1 = slot 2). Each slot's block stream is
    // its own; hps_io serves ONE transfer at a time and shares
    // sd_buff_addr/sd_buff_dout/sd_buff_wr across slots, so only the request side and the
    // core->host data leg are per slot.
    input         fdd_mounted,
    input  [63:0] fdd_size,
    output [31:0] fdd_lba,
    output  [5:0] fdd_blk_cnt,
    output        fdd_rd,
    output        fdd_wr,
    input         fdd_ack,
    output [15:0] fdd_buff_din,
    input         fdd1_mounted,
    input  [63:0] fdd1_size,
    output [31:0] fdd1_lba,
    output  [5:0] fdd1_blk_cnt,
    output        fdd1_rd,
    output        fdd1_wr,
    input         fdd1_ack,
    output [15:0] fdd1_buff_din,
    // The SECOND HARD DISK's image slot (hps_io slot 3, "Mount HDD2"): bank 1's master when the
    // OSD's IDE bank 1 field says HDD2 (`ide_bank1_hdd`). hps_io's shared img_readonly applies.
    input         hdd1_mounted,
    input  [63:0] hdd1_size,
    output [31:0] hdd1_lba,
    output  [5:0] hdd1_blk_cnt,
    output        hdd1_rd,
    output        hdd1_wr,
    input         hdd1_ack,
    output [15:0] hdd1_buff_din,
    // The CD-ROM (hps_io slot 4, CDROM_EN): bank 1's ATAPI master (pc9821_atapi). Read-only, so
    // the slot has no write leg; its CD-DA stream goes to the top level's cdda ring.
    input         cd_mounted,
    input  [63:0] cd_size,
    output [31:0] cd_lba,
    output  [5:0] cd_blk_cnt,
    output        cd_rd,
    input         cd_ack,
    input         cdda_req,
    input         cdda_req4,     // the ring has room for four sectors (the drive's read-ahead)
    input         cdda_played,   // one pulse per sector's worth of samples sent to the speakers
    output        cdda_flush,    // one cycle: the player stopped, paused or moved; empty the ring
    output        cdda_wr,
    output [31:0] cdda_data,

	input         ps2_kbclk_in,
	input         ps2_kbdat_in,
    input  [10:0] ps2_key,
    // hps_io's parsed PS/2 mouse packet (sys/hps_io.sv:121-122), handed to
    // pc9821_mouse through pc9821_iobus: [24] toggles once per packet,
    // [23:16] Y delta (PS/2: positive = up), [15:8] X delta (positive =
    // right), [2:0] {middle, right, left}, 1 = pressed.
    input  [24:0] ps2_mouse,
	output        ps2_kbclk_out,
	output        ps2_kbdat_out,

	// Host keyboard LEDs for hps_io, in its {scrolllock, numlock, capslock} order.
	output [2:0]  kbd_led_status,

    // Debug stream up to UART bridge. dbg_uart_accept is that FIFO's handshake back: it is high
    // in a cycle the byte on dbg_uart_byte was TAKEN, and pc9821_dbg_record holds the byte and
    // its strobe until it sees it, so a report cannot outrun the FIFO. It is a
    // level, and it is the FIFO's whole enqueue decision - the reset banner and the instruction
    // trace outrank this source there, so "room" alone is not the condition.
    output  [7:0] dbg_uart_byte,
    output        dbg_uart_we,
    // One-cycle: the instruction ring's freeze trigger (the end of a GVRAM drawing burst, or a
    // display/access page flip, rate-limited). 0 when PERF_LOG_EN=0.
    output        trace_trig,
    // PC-98 crash-recorder / probe taps (z486 dbg_* outputs). Pure observation of existing CPU state;
    // the crash recorder, its OSD debug view and its snapshot window read them at the
    // top level. A tap left unread there is dropped by the fitter.
    output        cpu_dbg_gate_read,  // one pulse per accepted IDT/IVT gate read
    output [31:0] cpu_dbg_gate_addr,  // its linear address
    output  [2:0] cpu_dbg_pf_code,    // latched page-fault error code
    output [31:0] cpu_dbg_pf_addr,    // latched faulting linear address
    output [31:0] cpu_dbg_eflags,
    output        cpu_dbg_page_fault,
    output [31:0] cpu_dbg_walk_pde,   // page walker's last PDE read
    output [31:0] cpu_dbg_walk_pte,   // page walker's last PTE read
    output [31:0] cpu_dbg_cr3,
    output [15:0] cpu_dbg_SP,
    output        cpu_dbg_issue,      // instruction issue pulse
    output [31:0] cpu_dbg_issue_eip,  // and the IP that will execute next
    /* verilator lint_off UNUSEDSIGNAL */   // PERF_LOG_EN=0: the compiled-out telemetry reads this back
    input         dbg_uart_accept,
    /* verilator lint_on UNUSEDSIGNAL */
    output        mpu_uart_tx,
    // Whether the MPU-PC98II is present to the guest: z486_mister.sv's OSD UART mode is MIDI.
    // A runtime select of device presence, meaningful only with MPU_EN (see the card's block).
    /* verilator lint_off UNUSEDSIGNAL */   // MPU_EN=0: no card to present
    input         mpu_present,
    /* verilator lint_on UNUSEDSIGNAL */
    // The run-time SDRAM_CLK phase instrument (SDRAM_PHASE_DYN, a test-only build): the step
    // handshake to the top level's pc9821_sdram_dps, which drives the main PLL's phase-shift ports
    // on the PLL's scan clock. With SDRAM_PHASE_DYN 0 the outputs are constant 0 and the inputs
    // are unread.
    output        sdph_step_req,
    output        sdph_step_up,
    /* verilator lint_off UNUSEDSIGNAL */   // SDRAM_PHASE_DYN=0: no instrument reads these
    input         sdph_step_ack,
    input         sdph_fault,
    /* verilator lint_on UNUSEDSIGNAL */

    input   [2:0] ram_size,       // OSD guest RAM size, log2(MiB): 0..6 = 1..64 MiB
    // The installed SDRAM module's guest-size CEILING (z486_mister's ram_size_max: code 4/5/7
    // for the 32/64/128 MB module classes). `ram_size` arrives already clamped to it; this port
    // exists because the pack's base is the ceiling rather than the selected size.
    input   [2:0] ram_size_max,
    input         kbd_layout_jis, // OSD Keyboard: 1 = JIS host layout, 0 = US (pc9821_kbd)
    // OSD: WHICH MACHINE'S PORT-0xF0 MACHINE-ID STRAP to answer, a four-bit field. 0 =
    // PC-9821Xe10 (the measured strap, and the config-less default), 1 = PC-9821Xe,
    // 2..15 reserved. The pack file IS the firmware set (the MGL chooses it); the port-0xF0
    // strap is the one observable the two ITFs read differently, so this field reaches
    // pc9821_iobus's HX_00F0 strap LUT and nothing else. The LUT reads a reset-qualified
    // latch (pc9821_iobus's bios_set_eff), so the selection applies at machine reset /
    // reload only - the `reset || !cpu_run` strobe the iobus instance below is held in -
    // and never mid-run.
    input   [3:0] bios_set,
    // OSD: the GDC-clock strap, PC-9821 port 0x31 bit 7. 0 = the measured machine's 0xF3
    // (2.5 MHz) and 1 = 0x73 (5 MHz). The BIOS turns that bit into work-area 0x54D bit 5
    // at POST (BIOS.ROM@0xFD93C) and the display-mode helper derives 0x54D bit 2 from it,
    // which is the byte the games read for the GDC clock and the SCROLL im bit
    // (rec98/th01/hardware/scrollup.cpp:22-27). It reaches pc9821_iobus's HX_0031 read arm
    // and nothing else. Like bios_set, the arm reads a reset-qualified latch
    // (gdc_strap_eff), so the selection applies at machine reset / reload only.
    input         gdc_clock_5m,
    // OSD: two SETUP items (docs/bios-setup.md), each reaching pc9821_iobus, whose ports carry
    // the evidence, and through its setup_cfg the configuration record and mirror in pc9821_cg.
    // 1 = 20 text lines (port 0x31 bit 3 set); 0 = 25, the measured machine.
    input         text_lines_20,
    // 1 = keep the memory switch (port 0x31 bit 4 clear, 0x871E bit 5 clear); 0 = initialise,
    // the measured machine.
    input         msw_keep,
    // SETUP's floppy disk mode, the OSD Floppy mode field's LIST POSITION: 0 = Auto (1M) (the
    // default, so an undriven port is it), 1 = 1M (the measured machine), 2 = Auto (640K),
    // 3 = 640K. See
    // pc9821_iobus's floppy_mode port.
    input  [1:0]  floppy_mode,
    // OSD: WHAT IS IDE BANK 1'S MASTER - 0 = the CD-ROM (the stock layout, the default), 1 = the
    // second hard disk (slot 3). A build without the CD drive drives 1 (bank 1 then has only the
    // disk to hold). Latched on the platform reset / reload strobe like the Machine field
    // (`ide_bank1_hdd_eff`), and the top level resets the platform when it changes, so the drive
    // on a cable never changes under a running guest.
    input         ide_bank1_hdd,
    // OSD: the CD audio volume, already decoded by pc9821_osd into pc9821_audio_volume's 5-bit
    // gain code (31 = 0 dB, 2 dB per step, 0 = mute). It drives vol_cd_l/r below; without the
    // CD drive's player (CDROM_AUDIO_EN 0) it is unread and the CD channel is the constant 0.
    /* verilator lint_off UNUSEDSIGNAL */   // CDROM_AUDIO_EN=0: no CD-DA channel to scale
    input   [4:0] cd_volume_code,
    /* verilator lint_on UNUSEDSIGNAL */
    // OSD: the ONE HARDWARE-switch field the `P1` DIP Switch page still owns, `Boot order`.
    // It reaches pc9821_crtc's TRAM seed and nothing else. IT CARRIES A LIST POSITION, NOT A
    // VALUE: position 0 is the measured machine (the 0x00 FDD nibble), and pc9821_crtc
    // decodes the position into the memory-switch cell's field. That is why an undriven port
    // is harmless - it means the captured machine, the same convention `bios_set` (0 = the
    // Xe10 strap) and `gdc_clock_5m` (0 = 2.5 MHz) use. It is latched inside pc9821_crtc on
    // rst_n_sys - the same `reset || !cpu_run` strobe as bios_set and gdc_clock_5m - so a
    // mid-run change is picked up at the next machine reset and never under the running
    // firmware. THE BASE MEMORY (0xA3FEA bits 2:0) IS NOT A PORT: it is hardcoded to 640 KB
    // inside pc9821_crtc because the real Xe10 has no SETUP/DIP way to change it.
    input   [2:0] cfg_fdd_mode,
    // OSD CPU Speed: the LIST POSITION, which is cpu_throttle's `speed_sel` (src/z486/
    // cpu_throttle.sv rate_khz(): 0 = full, then 33, 25, 16, 12, 8, 6, 4, 3, 2, 1.5, 1, 0.75 and
    // 0.5 MHz; 14 and 15 reserved = full). Position 0 is a strict no-op (cpu_ce constant 1), so an
    // undriven port or a card with no config file is full speed at every profile. Only the CPU
    // slows: the bus, I/O and every device keep their real rates (src/z486/docs/throttle.md).
    input   [3:0] cpu_speed_sel,
    // OSD I/O timing (status[79]): 0 = Fast, 1 = Xe10, the machine's measured per-class I/O
    // access times and GVRAM store periods. A runtime level, passed straight to pc9821_iobus (its
    // io_timing_xe10 port says what each table charges and when a change applies) and through
    // pc9821_memory_subsystem to pc9821_gvram_arb (its Xe10 store table). An undriven port is Fast.
    input         io_timing_xe10,
	output wire        video_ce,
	// 0x09A8 bit 0 (pc9821_iobus's latch): the raster runs on the 31 kHz dot clock. A level on
	// clk_sys; the top moves the video PLL to the matching clock (pc9821_vpll_ctl).
	output wire        video_31k,
	output wire        video_blank_n,
	output wire        video_hsync,
	output wire        video_vsync,
	output wire [7:0]  video_r,
	output wire [7:0]  video_g,
	output wire [7:0]  video_b,

	// The PC-9801-86 card: the OPNA YM2608 and the 86-PCM, summed WIDE and
	// delivered UNCLAMPED here (the chain's LAST saturation is at the final DAC,
	// pc9821_audio_mix's mix_dry - NP2kai's _saturation_s16).
	// 20 bits: the FM+ADPCM sum is clamped to +-32,767 at the jt08_acc junction
	// (ymfm's clamp16, ymfm_opn.cpp:1410-1414), the AC-COUPLED (zero-mean) SSG is
	// added after that clamp (up to +-12,276 at the <<2 join), and a full-scale
	// PCM86 joins at [+255,996, -239,616].
	output [19:0] sample_86_l,
	output [19:0] sample_86_r,

	output        speaker_out,
	
	output  [4:0] vol_master_l,
	output  [4:0] vol_master_r,
	output  [4:0] vol_voice_l,
	output  [4:0] vol_voice_r,
	output  [4:0] vol_cd_l,
	output  [4:0] vol_cd_r,
	output  [4:0] vol_midi_l,
	output  [4:0] vol_midi_r,
	output  [4:0] vol_line_l,
	output  [4:0] vol_line_r,
	output  [1:0] vol_spk,
	// The 2-bit beeper volume from software-DIP 0x871E bits [3:2] (pc9821_iobus):
	// pc9821_audio_mix scales the speaker amplitude by it, 0 = exact mute (NP2kai
	// io/dipsw.c:44-57 -> beep_setvol, sound/beepg.c linear scale).
	output  [1:0] beep_vol,
	output  [4:0] vol_en,

    // Debug outputs for LEDs
    output reg [2:0]  debug_boot_stage,
    output reg    debug_sd_error,
	output        debug_bios_loaded,
	output        debug_first_instruction,
    // The access lamps (pc9821_disk_led): led_disk while any drive - a hard disk, the CD drive
    // or the floppy controller - moves data with its image, led_fdd for the floppy alone, each
    // held on for a display-only 50 ms after. z486_mister drives LED_DISK / LED_USER.
    output        led_disk,
    output        led_fdd,
    output reg [7:0]  debug_post_code,
    output reg        debug_post_write,

    // CPU state outputs (for simulation monitoring)
    output            cpu_pe,
    output            cpu_vm,
    output     [15:0] cpu_cs,
    output     [31:0] cpu_eip,
    output     [31:0] cpu_cs_base

);

parameter SYS_FREQ = 50_000_000;
// L1 caches: 4 KiB data + 4 KiB instruction (SET_BITS=6 = 64 sets x 4 ways x 16 B).
// The size is set ONCE at z486_mister.sv:297-298 (`DCACHE_SET_BITS`), which overrides this default; this
// parameter exists only as pc9821_system's interface to the vendored z486. Kept small to
// free M10K blocks (the GVRAM owns 256 and the Kanji font needs room) - the 486's 8 KiB
// unified cache is not needed by DOS/Touhou; the smaller cache is a deliberate choice.
parameter DCACHE_SET_BITS = 6;
parameter ICACHE_SET_BITS = 6;
parameter ENABLE_X87 = 1'b0;
// The serial console's PERFORMANCE LOG: the watchdog/PRF/GFX telemetry on dbg_uart_byte/dbg_uart_we.
// COMPILED OUT, NOT DISABLED, unless the build turns it on (z486_mister.sv's PERF_LOG_EN, which
// build_profile.py rewrites for the 'trace' profile): with 0 the whole telemetry section below
// does not exist in the netlist and the two output ports are tied off.
parameter PERF_LOG_EN = 1'b0;
// WHETHER THE MPU-PC98II SOUND CARD EXISTS on the device bus: its registers at 0xE0D0/0xE0D2,
// its 31250-baud MIDI-out line, and its IRQ. COMPILED OUT, NOT DISABLED, unless the build turns
// it on (z486_mister.sv's MPU_EN, which build_profile.py writes from mpu_en, on in every preset except trace):
// with 0 the device decode drops the card's two match lines, the device-select's mpu_cs is a
// constant 0, the module instance below does not exist, and mpu_uart_tx is the idle mark it
// always was. See pc9821_mpu.sv for what the card is.
parameter MPU_EN = 1'b0;
// THE RUN-TIME SDRAM_CLK PHASE INSTRUMENT (z486_mister.sv's SDRAM_PHASE_DYN; build_profile.py
// --dbg-sdram-phase, off in every preset): pc9821_sdram_phase_ctl on the device bus at
// 0x5FF0/0x5FF2. With 0 the select is a constant 0, the instance below does not exist and the
// read mux's arm is unreachable, so nothing is built.
parameter SDRAM_PHASE_DYN = 1'b0;
// A PC-9801-118 game port at 0x1480-0x1487 (pc9821_iobus's GAMEPORT_118). The Xe10 has none, so
// 0 (every build) leaves the eight ports open bus; pc9821_gameport stays for the OPNA's
// register 0x0E switch lines, the Xe10's own joystick path. 1 builds the -118's axis port.
parameter GAMEPORT_118 = 1'b0;
// 0x0EE0's read-back of the platform status byte (pc9821_iobus's DBG_STATUS_PORT): off in
// every build, so the port reads the machine's 0xFF.
parameter DBG_STATUS_PORT = 1'b0;
// THE CD-ROM (z486_mister.sv's CDROM_EN, build_profile.py's cdrom_en): pc9821_atapi as bank 1's
// master. With 0 the instance does not exist, its read-mux arm and IRQ term are constant 0 and
// bank 1 is an empty connector (port 0xF0 bit 6 set); the hard disk is bank 0's master either way. CDROM_AUDIO_EN adds the CD-DA player (PLAY/PAUSE/SUB-CHANNEL
// and the audio stream); it is meaningful only with CDROM_EN.
parameter CDROM_EN = 1'b0;
parameter CDROM_AUDIO_EN = 1'b0;
// The CD drive's command log (pc9821_atapi LOG_EN) on dbg_uart_byte/dbg_uart_we, which carry it only
// when the telemetry (PERF_LOG_EN) is compiled out. A debug instrument; off in every preset.
parameter CDROM_LOG_EN = 1'b0;
// THE GRAPHICS GDC'S DRAW PACING (z486_mister.sv's GDC_WRITE_PACE_NS / GDC_FIG_PACE_NS,
// build_profile.py --gdc-write-pace / --gdc-fig-pace; 0 in every preset): pc9821_gdc2's
// WRITE_PACE_NS and FIG_PACE_NS, each WRITE unit / figure step in real ns (the Xe10's is 1400).
// 0 = unpaced, today's engine; the paced branch const-folds away.
parameter integer GDC_WRITE_PACE_NS = 0;
parameter integer GDC_FIG_PACE_NS = 0;
// THE DEBUG-UART INSTRUMENT FRAMEWORK (build_profile.py --dbg-*; docs/mister-testing.md,
// "The debug UART"). Each is a compile-time parameter, off in every preset,
// and the unselected instrument does not exist: the generate-if below instantiates nothing, the
// mux is absent and dbg_uart_byte/we are the constants they always were. They share the CD log's
// UART arm (so they need PERF_LOG_EN = 0) and pc9821_dbg_mux interleaves them on record boundaries.
//   DBG_GDC_EN      pc9821_gdc_log: the display programming (both GDCs, the mode registers)
//   DBG_FDC_EN      pc9821_fdc_log: the floppy controller's ports, its interrupt, DMA channel 2
//   DBG_CPU_EN      pc9821_dbg_cpu's sampler (CS:EIP, INTA counts, PIC state, VSYNC, port events)
//   DBG_SNOOP_EN    ... its physical-address memory snoop over [DBG_SNOOP_LO, DBG_SNOOP_HI)
//   DBG_TRIG_KIND   ... its frozen instruction trace and the trigger (0 = no trace; see the module)
//   DBG_LAST_MS     ... its LAST-occurrence mode: re-arm on every match, dump after this many quiet ms
//   DBG_TRACE_AW    ... its trace ring depth, 2^DBG_TRACE_AW issues (default 9, the module's own)
parameter DBG_GDC_EN = 1'b0;
parameter DBG_FDC_EN = 1'b0;
parameter DBG_CPU_EN = 1'b0;
parameter DBG_SAMPLE_MS = 10;
parameter DBG_SNOOP_EN = 1'b0;
parameter [31:0] DBG_SNOOP_LO = 32'h0;
parameter [31:0] DBG_SNOOP_HI = 32'h0;
parameter DBG_TRIG_KIND = 0;
parameter [31:0] DBG_TRIG_ADDR = 32'h0;
parameter [15:0] DBG_TRIG_CS = 16'h0;
parameter [31:0] DBG_TRIG2_LO = 32'h0;
parameter [31:0] DBG_TRIG2_HI = 32'h0;
parameter DBG_ARM_S = 0;
parameter DBG_POST = 32;
parameter DBG_LAST_MS = 0;
parameter DBG_TRACE_AW = 9;
// THE GATHER SESSION'S ENTRY COUNT (the G3 drain shape):
// how many same-row PEGC stores one backend request carries. COMPILE-TIME, threaded from
// z486_mister.sv's one GATHER_K the same way SYS_FREQ is, into both the store buffer's grouping
// and the controller's session engine - the two must agree, so there is one value for both.
parameter GATHER_K = 4;

wire [31:2] z_addr;
wire [3:0] z_be;
wire [7:0] z_burstcount;
wire z_line_read, z_valid, z_write, z_io, z_inta;
wire [31:0] z_dout;
reg [31:0] z_din;
reg z_ready, z_resp_valid;
// The CPU-side halves of the handshake (the gated clock domain); z_valid/z_inta above are the
// PLATFORM's view of the request and z_ready/z_resp_valid/z_din the platform's answer, and
// pc9821_cpu_bus_bridge (below) joins them. Everything in the platform reads the z_* view.
wire zc_valid, zc_inta, zc_ready, zc_resp_valid;
wire [31:0] zc_din;
wire z_intr;
// The CPU exports no L1 lookup/miss pulses, no internal interrupt state and no register
// taps, so the telemetry records carry no fields for them. Its observation ports are the
// crash-recorder taps, which are this module's own output ports (declared in the header),
// driven by the z486 instance and passed up unchanged.
reg  [7:0] inta_count;
reg        z_inta_d;

// INTA pulses actually issued by the CPU. If the PIC holds pending, unmasked
// requests (IMR/IRR in the telemetry) and this stays 0, the CPU never reached
// its interrupt-acknowledge path at all, which separates "not delivered" from
// "delivered but mishandled". Reset state: the counter is PER RESET EPOCH and
// starts at 0/0 - unreset it would X-lock in 4-state sim (the `!=` is X, the arm
// never fires) and run across warm resets, so no run's count would be readable.
always @(posedge clk_sys) begin
    if (reset) begin
        z_inta_d  <= 1'b0;
        inta_count <= 8'd0;
    end else begin
        z_inta_d <= z_inta;
        if (z_inta && !z_inta_d && inta_count != 8'hFF) inta_count <= inta_count + 8'd1;
    end
end
wire [31:0] inta_din;
wire inta_ready;
wire triple_fault_reset;

wire mem_cpu_ready, mem_cpu_resp_valid;
wire rom_ready, load_error, cpu_run;
wire [31:0] mem_cpu_dout;
wire cpu_mem_valid = z_valid && !z_io && !z_inta;

wire [31:0] io_cpu_dout;
wire io_cpu_ready, io_cpu_resp_valid;
wire device_io_wr, device_io_rd;
wire [15:0] device_io_addr;
wire [7:0] device_io_din, device_io_dout, gdc_io_dout;
wire gdc_vsync_irq, gdc_disp, gdc_de;
// The EGC gate (FF2 num 2 AND 0x7C bit 7) and its register file. The registers
// are latched by pc9821_iobus from 0x04A0-0x04AE; the engine that consumes them
// is pc9821_egc.sv, instantiated in the memory subsystem so its VRAM accesses go
// through the same backend port as every other GVRAM access.
wire gdc_egc_gate;
// mode2_egc's NEXT state, from pc9821_crtc: pc9821_egc_mem_gate registers the EGC x GRCG gate
// from both sources' next state.
wire gdc_egc_gate_nx;
// 0x09A8 bit 0 (pc9821_iobus): the 31 kHz dot clock (pc9821_dot_ce) and monitor range (pc9821_crtc).
wire crt31k;
// The 0x9A0 extended-video query state (pc9821_crtc -> pc9821_iobus, which owns
// the port): the bits NP2kai's gdc_i9a0 query table reads.
wire [10:0] gdc_ff2_state;
// The register file is gated by the EGC mode latch alone (NP2kai io/egc.c:24); a
// GVRAM store needs the GRCG's CG-mode bit 7 as well (vacctbl index VOPBIT_EGC &&
// VOPBIT_GRCG, i386c/cpumem.c:287-295), so `gdc_egc_mem_gate` is the mode AND the
// GRCG's expand gate the GRCG exports back through the memory subsystem.
wire mem_grcg_expand;
// mode bit 7's NEXT state, from pc9821_grcg through pc9821_memory_subsystem.
wire mem_grcg_expand_nx;
// The EGC x GRCG memory gate, REGISTERED from both sources' next state (pc9821_egc_mem_gate,
// instantiated below once rst_n_sys is available): a true pipeline relocate, so gate(t) is
// bit-identical to the combinational `gdc_egc_gate && mem_grcg_expand` in every cycle, while
// the flop cuts the crtc-launched GVRAM-M10K cone (docs/timing.md).
wire gdc_egc_mem_gate;
wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg,
             egc_sft, egc_leng;
wire        egc_shift_we;
// Port 0x64: any write arms the one-shot VSYNC IRQ latch (NP2kai gdc_o64;
// ReC98's INT 0Ah handler rearms it after every PIC EOI).
// gdc_cs is the device-select complement, declared before its first reader below; the
// device_select instance that drives it is with the rest of the chip selects below.
wire gdc_cs;
wire gdc_vsync_arm = device_io_wr && gdc_cs && (device_io_addr == 16'h0064);
wire [3:0] top_bank;
// The 0x043F 0x2 nibble's window state: 0 = identity/VRAM, 1 = the 64 KiB page, 2 =
// unmapped. Latched in the iobus; the mapper owns the window (pc9821_memory_map).
wire [1:0] ems_state;
wire sound_extend;
// System port C bit 3, the beeper's MUTE (pc9821_iobus).
wire beep_mute;
// Slave PIC IRQ11, driven by the FDC model inside pc9821_iobus (see the
// slave_irq concatenation below and pc9821_fdc). The FDC's 2DD port window
// (0xC8-0xCC) puts the SAME level on IRQ10 instead: one controller, two
// destinations, selected by the 0x00BE strap (pc9821_iobus's fdc_irq10).
wire fdc_irq;
wire fdc_irq10;
// Slave PIC IRQ13 (the bus mouse's periodic event: NP2kai mouseint's
// pic_setirq(0x0d), io/mouseif.c:131-140), driven by pc9821_mouse inside
// pc9821_iobus and routed into slave_irq[5] below.
wire mouse_irq;
wire ide_rom_enable, ide_ram_gate, a20_enable, cpu_reset_req;
wire [1:0] d8_bank;
wire [7:0] win0_sel;
wire       win0_sel_moved;   // pc9821_iobus's registered `win0_sel != 8'h08`
wire bios_ram_gate;
// 0x043F's 0x8 nibble, the 0xF8000-0xFFFFF window's writable-shadow enable. Latched in
// pc9821_iobus, consumed by pc9821_memory_subsystem.
wire top_shadow_en;
// pc9821_iobus's one-cycle reboot strobe (the 0x534 soft reset, a software reboot). It is a
// reset class like `reset`: it clears pc9821_memory_subsystem's top-window shadow-dirty flag and
// resets the IDE devices' task files (ide_dev_rst_n, below).
wire soft_reboot;
// 0x043B bit 2, the 15-16 MiB system-space window. pc9821_iobus latches it and the memory
// subsystem needs it BEFORE its route selects, so it is wired straight across.
wire sys16m_en;
wire [15:0] unmapped_writes, unmapped_reads, last_unmapped_port;

// The ARTIC counter's upper half, straight from the iobus. The watchdog message's U FIELD
// reports THIS rather than the last unmapped port, because it is what is informative at the
// stall it exists to diagnose: a machine that boots the whole ITF and then spins forever in the
// IDE option ROM's delay() helper at BANK3@0x0B2A, which reads this exact value with in ax,0x5E
// (no unmapped port is involved there). `last_unmapped_port` is still exported below.
/* verilator lint_off UNUSEDSIGNAL */   // PERF_LOG_EN=0: the watchdog's I/O taps here lose their only reader
wire [15:0] artic_hi;
wire [7:0] io_post_code;
wire io_post_write;
wire [3:0] io_dbg_gate;
// The core's native whole-L1 cache flush (src/z486/docs/platform-integration.md):
// iobus pulses cache_flush_req on every MAPPING/guest flush trigger, z486 walks
// both L1s (136 cycles) and answers cache_flush_done; the write completes on it.
// The DMA side does not ask for a walk: it snoops per accepted bus-master write
// (dma_snoop_valid below), which is the machine's EADS# and costs the CPU no stall
// (T24). The I/O family still uses the walk because a bank/EMS/window remap moves
// a whole region's physical names at once, not one written line.
wire cache_flush_req;
wire cache_flush_busy;
wire cache_flush_done;

// The DMA-side external snoop (the 486's EADS#), from pc9821_iobus's uPD71071
// bus-master port: the write AS THE BACKEND ACCEPTS IT invalidates its line in
// both L1s (z486 routes snoop_addr/snoop_valid to the D$ and to the I$ invalidate
// port, src/z486/memory.sv). A real 486 snoops per external write and software
// does not flush after a floppy DMA, so without this the disk buffer stays stale.
// Gating on the accept (dma_mem_ready) is what
// makes it correct: the invalidate cannot run before the byte has landed, and a
// CPU line cached between two writes of the same line is invalidated again by the
// next write to that line's set. Because this pulse is in the clk_sys domain and z486
// samples it on the GATED cpu_clk (l1_cache.sv:928), it is routed through
// pc9821_cpu_bus_bridge, which holds it for the CPU's next enabled edge - a pulse
// fed straight in would be lost whenever cpu_ce is 0 (any OSD CPU Speed but Full).
// A whole-L1 walk per DMA/FDC completion would hold cpu_ready low for 136 cycles.
wire dma_snoop_valid = dma_mem_req && dma_mem_we && dma_mem_ready;
// The line it names is the byte's address AFTER the memory map's window-0 move (the
// subsystem's dma_snoop_addr): a byte the DMA writes through a moved 0x0461 window lands in
// RAM under that RAM's own name, which is the name the CPU may hold cached (the window alias
// itself is uncached, win0_unmapped below).
wire [31:0] dma_snoop_addr;

// THE DMA-WRITE BACK-PRESSURE. The bridge's snoop hold is ONE entry, so a
// second DMA write accepted before the CPU's next enabled edge would take its place in
// the address mux and the first write's line would never be invalidated - silently on
// hardware (the bridge's check is simulation-only). While a snoop waits (dma_snoop_busy),
// the next DMA WRITE byte is therefore neither PRESENTED (dma_mem_req_pres drives the
// memory subsystem's mem_valid DMA arm, pc9821_memory_subsystem.sv:1723 `assign mem_valid`) nor ACCEPTED
// (dma_mem_ack is the dma_ready the DMAC sees, :1500). Both terms are needed: the
// subsystem's owner lock releases on mem_ready (:1477 `else if (mem_ready || !mem_valid)`),
// so gating the accept alone would let it re-present the same byte and the backend
// re-accept it every cycle. The uPD71071 holds mem_req as a LEVEL through S_MEM until
// mem_ready (pc9821_dmac.sv:486 `S_MEM: if (mem_ready) begin`), so the byte waits for the
// CPU edge; reads are never snooped and are not gated. The cost is at most one CPU clock
// period per written byte - the pacing a real 486's EADS# imposes (one invalidate per CPU
// clock), and still 8x the FDC's 62.5 kB/s at the slowest 0.5 MHz setting on an 80 MHz
// build. The bridge's $fatal stays as the loud backstop if the gating itself breaks.
wire dma_snoop_busy;                              // pc9821_cpu_bus_bridge's hold occupancy
wire dma_write_hold   = dma_mem_we && dma_snoop_busy;
wire dma_mem_req_pres = dma_mem_req && !dma_write_hold;   // what the subsystem may present
wire dma_mem_ack      = dma_mem_ready && !dma_write_hold; // what the DMAC may take as ready
wire [7:0] io_itf_stage;
// The most recent I/O access, latched in pc9821_iobus and reported by the watchdog message's
// IO/DR/IV fields so a freeze loop's polled port shows up in a serial capture.
wire [15:0] dbg_last_io_addr;
wire  [7:0] dbg_last_io_data;
wire        dbg_last_io_rd;
wire        dbg_last_io_wr;
wire        dbg_last_io_stb;
// The FDC's own diagnostics, through iobus from pc9821_fdc: the stall record's
// FST/FCM/FRS/FCH fields. See pc9821_fdc for the packing and what each answers.
wire [7:0]  dbg_fdc_state;
wire [7:0]  dbg_fdc_cmd;
wire [31:0] dbg_fdc_result;
wire [31:0] dbg_fdc_chrn;
/* verilator lint_on UNUSEDSIGNAL */

// OSD RAM size (clamped by the DE10-Nano wrapper to what the installed module
// serves): the codes are the guest size, ascending -- 0..7 = 1/2/4/8/16/32/64/96
// MiB. Codes 0..6 are log2(MiB); code 7 is the design's deliberate ceiling and is
// not a power of two (see z486_mister.sv for the SDRAM budget that fixes it).
//
// TWO SIZES, DELIBERATELY DECOUPLED
//   guest_ram_bytes follows the OSD and is RE-SAMPLED ON EVERY OSD RESET, so a
//     changed size takes effect on the reset, not only on a core reload.
//   pack_base is the module CEILING (ram_size_max), latched with the pack. The
//     pack is written into SDRAM at that absolute address only during a download
//     and the HPS does not re-send it on an OSD reset, so a base that followed the
//     selected size would leave the mapper reading an unwritten region. The reserve,
//     the EMS/ROM-sum window, GVRAM and the PCM buffer all hang off pack_base. A
//     size above the module ceiling still needs a core reload.
function automatic [31:0] size_code_bytes(input [2:0] code);
    case (code)
        3'd0:    size_code_bytes = 32'h0010_0000; // 1 MiB
        3'd1:    size_code_bytes = 32'h0020_0000; // 2 MiB
        3'd2:    size_code_bytes = 32'h0040_0000; // 4 MiB
        3'd3:    size_code_bytes = 32'h0080_0000; // 8 MiB
        3'd4:    size_code_bytes = 32'h0100_0000; // 16 MiB
        3'd5:    size_code_bytes = 32'h0200_0000; // 32 MiB
        3'd6:    size_code_bytes = 32'h0400_0000; // 64 MiB
        3'd7:    size_code_bytes = 32'h0600_0000; // 96 MiB, the design's ceiling
        default: size_code_bytes = 32'h0600_0000; // x/z fall back to the ceiling
    endcase
endfunction
/* verilator lint_off PROCASSINIT */   // the initialisers are the registers' power-up values
reg [2:0] ram_size_sel = 3'd5;   // the guest size: re-sampled on reset, below
reg [2:0] pack_size_sel = 3'd5;  // the module ceiling: latched with the pack, above
/* verilator lint_on PROCASSINIT */
always @(posedge clk_sys) begin
    // The guest size follows the OSD on EVERY platform reset (an OSD Reset is a
    // platform reset), and also during the pre-load window so a core reload picks
    // up the config file's value. After the reset the latch freezes again while
    // rom_ready is high, exactly as before.
    if (reset || !rom_ready) ram_size_sel <= ram_size;
end
always @(posedge clk_sys) begin
    // The pack base is the module ceiling and is NOT re-sampled on a warm reset:
    // the pack is already placed at it and the HPS will not re-send it.
    if (!rom_ready) pack_size_sel <= ram_size_max;
end
wire [31:0] guest_ram_bytes = size_code_bytes(ram_size_sel);
wire [31:0] pack_base       = size_code_bytes(pack_size_sel);

// The configuration image's size input, in MiB, read back out of the one table above: both
// consumers (the CG store's seed in pc9821_gdc_text and the memory-switch pair's strap cell in
// pc9821_iobus) want a MiB count, and the ITF's own image is written in MiB.
wire [6:0] cfg_ram_mib = guest_ram_bytes[26:20];

// The one-byte POST/watchdog telemetry (port 0x0EE0, and the watchdog's "ST="):
// bit0 rom_ready, bit1 ioctl_download, bit2 cpu_run, bit3 ext_mem_busy, bit4
// load_error, bits 7:5 the RAM-size code. The size needs three bits (1..64 MiB =
// log2 0..6). `triple_fault_reset` is not mirrored here: the telemetry line
// carries it as its own TF= field.
wire [7:0] io_debug_status = {
    ram_size_sel, load_error, ext_mem_busy, cpu_run,
    ioctl_download, rom_ready
};

// The CPU's reset release: the platform hold, the SDRAM-ready term and the reset synchroniser,
// which live in their own module so they can be driven directly (tb_pc9821_cpu_reset_gate).
wire cpu_reset_n;
pc9821_cpu_reset_gate cpu_reset_gate (
    .clk(clk_sys), .reset(reset),
    .cpu_run(cpu_run), .hps_apply_reset(hps_apply_reset),
    .cpu_reset_req(cpu_reset_req), .mem_busy(ext_mem_busy),
    .cpu_reset_n(cpu_reset_n)
);

always @* begin
    z_din = mem_cpu_dout;
    z_ready = mem_cpu_ready;
    z_resp_valid = mem_cpu_resp_valid;
    if (z_io) begin
        z_din = io_cpu_dout;
        z_ready = io_cpu_ready;
        z_resp_valid = io_cpu_resp_valid;
    end else if (zc_inta) begin
        z_din = inta_din;
        z_ready = inta_ready;
        z_resp_valid = inta_ready;
    end
end

// Internal nets that cross between the device instances, declared before their first use
// (the iobus instance below reads all of them) so no name is used above its declaration
// under `default_nettype none`. The two stored terms are assigned in the device-select
// block below, where their inputs are declared.
wire cal_irq, cal_cdat;
// A drive on the bank-0 IDE connector (IDE unit 0, the hard disk): the port 0xF0 strap reports it
// (pc9821_iobus's ide_unit0_present). Assigned beside the ATA.
wire ide_unit0_present;
// ... and on the bank-1 connector (IDE unit 2): the CD drive or the second hard disk.
wire ide_unit2_present;
wire device_rd_wait;
wire device_rd_hold;
wire device_wr_wait;
// The reset seed's one-cycle strobe from pc9821_iobus: the store loads use it there and the
// CG-record restore in pc9821_cg uses it here, so both configuration stores reset on the same
// event (the reset assertion, a configuration change inside it, and the guest's 0x534 reboot).
// The two stores' restore walks have this one source, and setup_cfg is the OSD configuration
// both are built from.
wire sdip_seed_pulse;
wire [23:0] setup_cfg;

pc9821_iobus #(.SYS_CLOCK_HZ(SYS_FREQ),
               .MPU_EN(MPU_EN), .SDRAM_PHASE_DYN(SDRAM_PHASE_DYN),
               .GAMEPORT_118(GAMEPORT_118), .DBG_STATUS_PORT(DBG_STATUS_PORT)) iobus (
      .ide_unit0_present(ide_unit0_present), .ide_unit2_present(ide_unit2_present),
    .clk(clk_sys), .reset(reset || !cpu_run),
    // The OSD's Machine field: which port-0xF0 machine-ID strap to answer. See the port
    // comment at pc9821_system's declaration and
    // This instance's reset IS the field's reset/reload strobe (bios_set_eff inside): the
    // platform reset OR the pack-reload window, so the selection applies only there.
    .bios_set(bios_set),
    .io_timing_xe10(io_timing_xe10),
    // Same reset/reload strobe for the GDC-clock strap's latch (gdc_strap_eff inside).
    .gdc_clock_5m(gdc_clock_5m),
    // Port 0x31 bit 4 at HOLD when the OSD's Memory switch field says Keep, and whenever the
    // Boot order field seeds a non-default 0xA3FF2 nibble (positions 1..6; 0 and the unoffered
    // 7 decode to the measured nibble 0 in pc9821_text_mem's msw_fdd_nib), so the ITF's
    // memory-switch init (BANK4@0x5B9A) does not overwrite the seed. See pc9821_iobus's
    // msw_hold port.
    .msw_hold(msw_keep || ((cfg_fdd_mode != 3'd0) && (cfg_fdd_mode != 3'd7))),
    .text_lines_20(text_lines_20),
    .floppy_mode(floppy_mode),
    .cpu_addr({z_addr, 2'b00}), .cpu_din(z_dout), .cpu_be(z_be),
    .cpu_valid(z_valid && z_io && !z_inta), .cpu_write(z_write),
    .cpu_dout(io_cpu_dout), .cpu_ready(io_cpu_ready),
    .cpu_resp_valid(io_cpu_resp_valid), .debug_status(io_debug_status),
    .device_io_wr(device_io_wr), .device_io_rd(device_io_rd),
    .device_io_addr(device_io_addr), .device_io_din(device_io_din),
    .device_io_dout(device_io_dout), .device_rd_wait(device_rd_wait),
    .device_rd_hold(device_rd_hold), .device_wr_wait(device_wr_wait),
    // The one device-bus decode (its instance is inside the iobus): the chip selects every
    // device below takes. gdc_cs's wire is declared above its first reader.
    .pic_master_cs(pic_master_cs), .pic_slave_cs(pic_slave_cs), .pit_cs(pit_cs),
    .interrupt_cs(interrupt_cs), .cal_cs(cal_cs), .kbd_cs(kbd_cs),
    .ata_cs(ata_cs), .opna_cs(opna_cs), .pcm_cs(pcm_cs), .gameport_cs(gameport_cs),
    .mpu_cs(mpu_cs), .sdph_cs(sdph_cs), .gdc_cs(gdc_cs),
    .cal_cdat(cal_cdat),
    // The memory-switch pair's strap cell is seeded from the same size the CG seed uses (see
    // pc9821_gdc_text's configuration-image block and).
    .cfg_ram_mib(cfg_ram_mib), .cfg_seed_en(1'b1),
    // The machine-reset seed's one-shot: the CG record is restored by the same event (below).
    .sdip_seed_pulse(sdip_seed_pulse),
    // The OSD configuration the CG record and mirror are built from (pc9821_cg, below).
    .setup_cfg(setup_cfg),
    .top_bank(top_bank), .ide_rom_enable(ide_rom_enable), .d8_bank(d8_bank),
    .ide_ram_gate(ide_ram_gate),
    .ems_state(ems_state),
    .sound_extend(sound_extend),
    .beep_mute(beep_mute),
    .beep_vol(beep_vol),
    .fdc_irq(fdc_irq),
    .fdc_irq10(fdc_irq10),
    .fdd_present({2'b00, fdd_media_present}),
    .fdd_wp({2'b00, fdd_media_wp}),
    .fdd_chg({2'b00, fdd_media_chg}), .fdd_frame_tick(gdc_vsync_edge),
    .fdd_req(fdd_req), .fdd_req_hdr(fdd_req_hdr), .fdd_unit(fdd_unit),
    .fdd_c(fdd_c), .fdd_h(fdd_h), .fdd_tc(fdd_tc), .fdd_hd(fdd_hd), .fdd_mf(fdd_mf), .fdd_2hd(fdd_2hd), .fdd_rpm(fdd_rpm), .fdd_r(fdd_r), .fdd_n(fdd_n), .fdd_idx(fdd_idx),
    .fdd_ready(fdd_ready), .fdd_rdy(fdd_rdy), .fdd_hdrv(fdd_hdrv), .fdd_err(fdd_err),
    .fdd_dout(fdd_dout), .fdd_hr(fdd_hr), .fdd_hn(fdd_hn), .fdd_hs(fdd_hs),
    .fdd_adv(fdd_adv), .fdd_req_wr(fdd_req_wr), .fdd_din(fdd_din), .fdd_abort(fdd_abort),
    .dma_mem_addr(dma_mem_addr), .dma_mem_addr_nx(dma_mem_addr_nx), .dma_mem_load(dma_mem_load), .dma_mem_din(dma_mem_din), .dma_mem_be(dma_mem_be),
    .dma_mem_req(dma_mem_req), .dma_mem_we(dma_mem_we),
    .dma_mem_ready(dma_mem_ack), .dma_mem_dout(dma_mem_dout),
    .dma_mem_resp_valid(dma_mem_resp_valid),
    .mouse_irq(mouse_irq), .ps2_mouse(ps2_mouse),
    .bios_ram_gate(bios_ram_gate),
    .top_shadow_en(top_shadow_en),
    .soft_reboot(soft_reboot),
    .win0_sel(win0_sel),
    .win0_sel_moved(win0_sel_moved),
    .sys16m_en(sys16m_en),
    .a20_enable(a20_enable), .cpu_reset_req(cpu_reset_req),
    // The CPU's own shutdown is the same CPU-reset class as 0xF0/0x534; the
    // block that owns cpu_reset_req and the A20 gate handles it, so the request
    // never leaves the core (sec.3.2's defect was exporting it as BUTTONS).
    .triple_fault_reset(triple_fault_reset),
    .unmapped_writes(unmapped_writes), .unmapped_reads(unmapped_reads),
    .last_unmapped_port(last_unmapped_port), .post_code(io_post_code),
    .dbg_artic_hi(artic_hi),
    .dbg_last_io_addr(dbg_last_io_addr), .dbg_last_io_data(dbg_last_io_data),
    .dbg_last_io_rd(dbg_last_io_rd), .dbg_last_io_wr(dbg_last_io_wr),
    .dbg_last_io_stb(dbg_last_io_stb),
    .dbg_fdc_state(dbg_fdc_state), .dbg_fdc_cmd(dbg_fdc_cmd),
    .dbg_fdc_result(dbg_fdc_result), .dbg_fdc_chrn(dbg_fdc_chrn),
    .post_write(io_post_write),
    .cache_flush_req(cache_flush_req), .cache_flush_busy(cache_flush_busy),
    .cache_flush_done(cache_flush_done), .crt31k(crt31k), .dbg_gate(io_dbg_gate),
    .dbg_itf_stage(io_itf_stage),
    .egc_gate(gdc_egc_gate),
    .gdc_ff2_state(gdc_ff2_state),
    .egc_access(egc_access), .egc_fgbg(egc_fgbg), .egc_ope(egc_ope),
    .egc_fg(egc_fg), .egc_mask(egc_mask), .egc_bg(egc_bg),
    .egc_sft(egc_sft), .egc_leng(egc_leng), .egc_shift_we(egc_shift_we)
);

// window-0's overlay verdict for the z486 L1 classification. 0x0461 maps the 128 KiB window at 0x80000-0x9FFFF onto the pages
// (value & 0xFE) and +1 at value*0x10000. ANY moved window is kept out of the
// L1 (NO_ALLOC), not only one whose target is a device window or past RAM:
// the translation happens outside the CPU, so a window over plain RAM is ONE
// byte with TWO physical names, and caching both lets a store through the
// canonical name leave the window's line stale (a stale-alias read the L1
// flush on the 0x0461 write only clears at the NEXT remap).
// Uncached, the window always reads the backend, which the canonical name's
// write-through store queue keeps current (an uncached read waits for
// storeq_empty, l1_cache.sv). RESIDUAL: a store THROUGH the window does not
// invalidate a line cached under the canonical name. z486 already routes the
// external snoop to BOTH L1s (memory.sv: dcache_inst and the I$ invalidate
// port, set-wide on the D$), and the platform drives it from the DMA's
// accepted writes (dma_snoop_valid below, T24); closing THIS residual is a
// separate platform change - driving the snoop with the translated address on a
// CPU window store, not a fork one. The real machine's window cacheability
// (KEN#) is uncaptured. Cost: accesses through a moved window are uncached.
wire win0_unmapped = win0_sel_moved;   // == (win0_sel != 8'h08) every cycle (pc9821_iobus)

// ---- the CPU throttle (OSD CPU Speed) ----
// z486 has no speed input: a slower CPU is the same CPU seeing fewer clock edges. cpu_throttle
// picks which clk_sys edges it gets (cpu_ce, registered; a Bresenham spread at the selected
// rate, derived from CLOCK_RATE_KHZ so a setting means the same MHz at every profile), the
// clock-control block gates clk_sys with it for z486 ONLY, and the bridge holds every
// handshake and pulse for the CPU's next enabled edge (src/pc9821/core/pc9821_cpu_gate.sv,
// src/z486/docs/throttle.md and src/z486/docs/cpu-review2-2026-10-10.md section 7). Position 0 makes cpu_ce
// constant 1: the bridge is then a wire and the core is cycle-identical to an ungated one.
// The reset is the CPU's own (its hold is far longer than the three cycles cpu_throttle and the
// gate's one-cycle-ahead enable stage, pc9821_cpu_clk.sv, need to force cpu_ce while it is low).
localparam int CPU_THROTTLE_KHZ = SYS_FREQ / 1000;
wire cpu_ce_next, cpu_ce, cpu_clk;
cpu_throttle #(.CLOCK_RATE_KHZ(CPU_THROTTLE_KHZ)) u_cpu_throttle (
    .clk(clk_sys), .reset_n(cpu_reset_n), .speed_sel(cpu_speed_sel), .cpu_ce(cpu_ce_next)
);
pc9821_cpu_clk u_cpu_clk (.clk(clk_sys), .ce_next(cpu_ce_next), .ce(cpu_ce), .gclk(cpu_clk));
wire zc_flush_req, zc_flush_busy, zc_flush_done, zc_triple_fault;
wire zc_snoop_valid;   // the DMA snoop after the bridge's pulse-hold (see the bridge)
wire [31:0] zc_snoop_addr;
wire [2:0] zc_dbg_pulse;   // dbg_issue, dbg_gate_read, dbg_page_fault (one CPU cycle each)
pc9821_cpu_bus_bridge u_cpu_bridge (
    .clk(clk_sys), .reset_n(cpu_reset_n), .cpu_ce(cpu_ce),
    .c_valid(zc_valid), .c_inta(zc_inta), .p_valid(z_valid), .p_inta(z_inta),
    .p_ready(z_ready), .c_ready(zc_ready),
    .p_resp_valid(z_resp_valid), .p_din(z_din), .c_resp_valid(zc_resp_valid), .c_din(zc_din),
    .p_flush_req(cache_flush_req), .c_flush_req(zc_flush_req),
    .c_flush_busy(zc_flush_busy), .p_flush_busy(cache_flush_busy),
    .c_flush_done(zc_flush_done), .p_flush_done(cache_flush_done),
    .p_snoop_valid(dma_snoop_valid), .p_snoop_addr(dma_snoop_addr),
    .c_snoop_valid(zc_snoop_valid), .c_snoop_addr(zc_snoop_addr),
    .p_snoop_busy(dma_snoop_busy),
    .c_triple_fault(zc_triple_fault), .p_triple_fault(triple_fault_reset),
    .c_dbg_pulse(zc_dbg_pulse),
    .p_dbg_pulse({cpu_dbg_page_fault, cpu_dbg_gate_read, cpu_dbg_issue})
);

// The grouped `dbg` (z486_dbg_t) output is deliberately not named: it duplicates the
// individual dbg_* taps below, which the telemetry reads, and naming it would force
// tests/pc9821/z486_stub.sv to carry the struct type from z486_pkg, which the stub
// benches do not compile.
/* verilator lint_off PINMISSING */
z486 #(
    .PROTECT_UMA_ROM(0),
    .DCACHE_SET_BITS(DCACHE_SET_BITS),
    .ICACHE_SET_BITS(ICACHE_SET_BITS),
    // x87 is off by default (ENABLE_X87 = 0 above) and no OSD bit turns it on: the
    // FPU's ports are not modelled. The parameter reaches the CPU from here.
    .ENABLE_X87(ENABLE_X87),
    // DEVICE-MMIO WINDOW: OFF. Enabling it with DEVICE_MMIO_MASK 32'hFE00_0000 and
    // device_mmio_base 32'h0200_0000 below would classify 32-64 MiB as device memory. That 32 MiB literal is the PACK BASE FOR A
    // 64 MB SDRAM MODULE (the pack sits at the module ceiling), not a property of the
    // machine: the real Xe10 tops out at 32 MB, but the OSD's guest RAM reaches 96 MiB
    // on a 128 MB module and then 32 MiB of REAL GUEST RAM inside the window is served
    // L1-bypassed and uncached. Such a window would make the memory-size probe read open
    // bus rather than its own cache-patched write, but the runtime no-allocate bound two
    // lines below (ram_cache_top = guest_ram_bytes with RAM_BOUND_ENABLE) already gives
    // exactly that -- "never install a line", so an uncached load waits for storeq_empty
    // and a probe write cannot survive in L1 -- for EVERY address at or above the guest
    // RAM top, and the L1 tag reach leaves everything above 128 MiB uncacheable anyway.
    // The window's range is a SUBSET of that bound when the guest is <= 32 MiB and a
    // subset of guest RAM when it is more, so it would be redundant at best and wrong at
    // worst. Upstream's own A0000-BFFFF role for this classifier is served here by the
    // device aperture in `Z486_PC98_MAP_PARAMS (C0000-FFFFF added to it), so nothing is
    // lost.
    .ENABLE_DEVICE_MMIO(0),
    // PC-98 memory map, from the vendored template's own preset: the whole
    // device aperture A0000-FFFFF uncached, the three alias windows, the
    // window-0 overlay range, A20-off as a bit-20 clear (Xe10 A20MAP:
    // BIT20-ONLY, overruling NP2kai's CPU_ADRSMASK and QEMU's a20_mask
    // 0x000FFFFF; the masked reset fetch 0xFFEFFFF0 is served by
    // pc9821_memory_subsystem's bios_top window), and the no-allocate bound at
    // the L1 tag reach. See docs/z486-local-patch.md.
    `Z486_PC98_MAP_PARAMS,
    // The no-allocate bound is additionally bounded at runtime by the OSD-selected
    // guest RAM top: cacheable RAM is exactly [0, guest_ram_bytes). See
    // docs/z486-local-patch.md and memory.sv's RAM_BOUND_ENABLE.
    .RAM_BOUND_ENABLE(1)
    // z486 has no speed input: a throttled CPU sees fewer clock edges
    // (src/z486/docs/throttle.md).
) cpu (
    .clk(cpu_clk), .reset_n(cpu_reset_n),
    .device_mmio_enable(1'b0), .device_mmio_base(32'h0),   // OFF: see ENABLE_DEVICE_MMIO above
    // The L1's fill-exclusion bound and window-0 verdict (see win0_unmapped
    // above): cacheable RAM is exactly [0, guest_ram_bytes), and the win0
    // overlay joins the direct class whenever its target does.
    .ram_cache_top(guest_ram_bytes), .win0_unmapped(win0_unmapped),
    .addr(z_addr), .be(z_be), .burstcount(z_burstcount),
    .line_read(z_line_read), .din(zc_din), .line_din(128'd0),
    .dout(z_dout), .valid(zc_valid), .ready(zc_ready), .write(z_write),
    .io(z_io), .resp_valid(zc_resp_valid), .line_resp_valid(1'b0),
    .intr(z_intr), .nmi(1'b0), .inta(zc_inta),   // NMI is never generated: no source, no OSD bit
    // A real DMA snoop exists on this platform: the uPD71071's accepted writes
    // drive the external invalidate through the bridge's pulse-hold (zc_snoop_valid
    // above), so it is captured on an enabled CPU edge even when cpu_ce is gated (the
    // same hold the flush request gets). z486 forwards it to
    // both L1s - the D$ clears the snooped SET (set-wide, l1_cache.sv) and the I$
    // tag-matches the line - and the native cache_flush below still serves the
    // I/O family's mapping changes (src/z486/docs/platform-integration.md).
    .snoop_addr(zc_snoop_addr), .snoop_valid(zc_snoop_valid),
    .cache_flush(zc_flush_req), .cache_flush_busy(zc_flush_busy),
    .cache_flush_done(zc_flush_done),
    .a20_enable(a20_enable),
    .single_step(1'b0),   // single-step is a debug aid, no OSD bit
    // z486's diagnostic switches (fast paths / L1 caches / x87 off): never requested here,
    // so the CPU runs exactly as before they existed.
    .fast_off_req(1'b0), .cache_off_req(1'b0), .x87_off_req(1'b0),
    .dbg_CS(cpu_cs), .dbg_EIP(cpu_eip), .dbg_CS_base(cpu_cs_base),
    /* verilator lint_off PINCONNECTEMPTY */   // x87 state has no telemetry field
    .dbg_pe(cpu_pe), .dbg_vm(cpu_vm), .dbg_x87_state(),
    /* verilator lint_on PINCONNECTEMPTY */
    .dbg_gate_read(zc_dbg_pulse[1]), .dbg_gate_addr(cpu_dbg_gate_addr),
    .dbg_pf_code(cpu_dbg_pf_code), .dbg_pf_addr(cpu_dbg_pf_addr),
    .dbg_eflags(cpu_dbg_eflags), .dbg_page_fault(zc_dbg_pulse[2]),
    .dbg_walk_pde(cpu_dbg_walk_pde), .dbg_walk_pte(cpu_dbg_walk_pte),
    .dbg_cr3(cpu_dbg_cr3), .dbg_SP(cpu_dbg_SP),
    .dbg_issue(zc_dbg_pulse[0]), .dbg_issue_eip(cpu_dbg_issue_eip),
    .triple_fault_reset(zc_triple_fault),
    // 486 LOCK#. No bus master on this platform honours it: the uPD71071 DMA is kept
    // coherent by the per-write external snoop above (the machine's EADS#, held for
    // the gated CPU clock by the bridge), and `lock` is sampled only for the L1's
    // locked-access path (src/z486/docs/platform-integration.md, "Bus lock").
    /* verilator lint_off PINCONNECTEMPTY */
    .lock()
    /* verilator lint_on PINCONNECTEMPTY */
);
/* verilator lint_on PINMISSING */

wire [13:0] tram_addr;
wire [7:0] tram_din, tram_dout;
wire tram_we;
// Memory-mapped CG window: the store stays in the GDC and the responder in the
// memory subsystem, so the two views of the selected glyph cannot disagree.
wire [4:0] cg_win_byte_sel;
wire cg_win_rd;
wire [7:0] cg_win_dout, cg_win_din;
wire cg_win_we;
wire [17:0] font_addr;   // the ANK table loads at words 0..2047; the slice in gdc_text drops the top
wire [15:0] font_data;
wire font_we;
// The CG block's variable read hold: the JIS glyph read is answered from the pack's SDRAM copy,
// so it holds the bus while the code's burst is in flight instead of
// answering the previous code's glyph. cg_rd_hold is the port-0xA9 hold; cg_win_byte_hold is
// the 0xA4000 window's.
wire cg_rd_hold, cg_win_byte_hold;
wire [18:0] font_req_addr;
wire font_req, font_word_valid;
wire [31:0] font_word_data;

// The memory subsystem's backend bus. It runs straight to the SDRAM/legacy
// memory ports (ext_mem0_*): the GRCG and the EGC are clients of the GVRAM block inside the
// subsystem, on the one four-plane GVRAM
// datapath. A GVRAM store is
// therefore expanded in clk_sys, one column at a time, on the same port the
// scanout reads -- there is no second route to the planes for the two engines to
// disagree about.
wire [31:0]  sub_mem_addr, sub_mem_din, sub_mem_din_hi, sub_mem_dout;
wire [3:0]   sub_mem_be;
wire [7:0]   sub_mem_burstcount;
wire         sub_mem_valid, sub_mem_write;
wire         sub_mem_gath;
wire [440:0] sub_mem_gath_extra;
wire         sub_mem_ready, sub_mem_resp_valid;

// The GRCG's register port (0x7C mode, 0x7E tiles). The engine lives inside
// pc9821_gvram_arb, so what crosses this boundary is only the two device-bus bytes
// that configure it.
wire grcg_port_we = device_io_wr && (device_io_addr == 16'h007C ||
                                     device_io_addr == 16'h007E);

// ---- the scanout's memory side ----
// pc9821_gvram owns the line fetch, the ping-pong line buffer and the pacing; the
// raster supplies only the line origin and the line tick, and reads the assembled
// columns back.
//
// The line origin is GDC2 SCROLL's display address counter, which pc9821_gdc_text
// already maintains (bit 15 is the 0xA4 display page, bits 14:0 the offset inside
// that page) -- the line-addressable fetch is exactly that shape, and it is what
// lets the 2.5 MHz strap's doubled pitch and the 480-/200-line modes work without
// the fetch assuming pitch == 80. gdc_gfx_walk_page is the PACKED walk's own page
// bit (the SCROLL start word's bit 14, pc9821_gdc2's gfx_walk_page): the packed
// fetch folds it with the 0xA4 term, the planar fetch takes scan_page alone.
wire [15:0] gdc_gfx_line_addr;
wire        gdc_gfx_walk_page;
// The line tick. The raster comes from the GDC's SYNC block (pc9821_crtc's geometry),
// so the tick is ONE clk_sys pulse at the last dot of the line, and its counter is reset by
// the SAME condition as the raster's
// own counter so the tick's phase cannot drift across the line. Both properties are
// load-bearing: pc9821_gvram's fetch treats the tick as a pulse and TOGGLES the
// ping-pong select on it, so a multi-clk level makes the displayed line advance by
// (level width mod 2), and a tick whose phase sits inside the active region toggles
// the buffer part-way along the line -- a static vertical shear. Both show on screen as
// a bouncing graphics plane.
// pixel_ce is the video-domain clock enable. It is declared here because the raster counter
// below is its first reader; its generator (pc9821_dot_ce, the exact 400/19 MHz enable) is further down.
wire pixel_ce;
// The line length the guest's SYNC block programs: 848 dots for the machine's power-on
// block (pc9821_crtc's geometry section), 800..896 for any block the 24 kHz clamp lets
// through.
wire [9:0] crtc_o_htotal;
reg [9:0] gvram_h_count;
reg       gvram_h_last;
wire      gvram_at_last = (gvram_h_count == (crtc_o_htotal - 10'd1));
always @(posedge clk_sys) begin
  if (reset || !cpu_run) begin
    gvram_h_count <= 10'd0;
    gvram_h_last  <= 1'b0;
  end else begin
    gvram_h_last <= gvram_at_last;
    if (pixel_ce) gvram_h_count <= gvram_at_last ? 10'd0 : gvram_h_count + 10'd1;
  end
end
// One clk_sys, on the leading edge of the last-dot level: the last dot of the line.
wire gvram_scan_line_tick = gvram_at_last & ~gvram_h_last;
// The read side is the pixel pipeline's: the mixer's read sequencer presents one
// column address per 8 dots and selects the buffer the fetch calls displayed
// The line origin and the tick above are the only inputs the
// scanout takes from the raster.
wire [6:0]  gvram_line_rd_addr;
wire        gvram_line_rd_sel;
wire [31:0] gvram_line_data;
wire        gvram_line_sel, gvram_line_ready;

/* verilator lint_off UNUSEDSIGNAL */   // PERF_LOG_EN=0: the GVRAM telemetry taps here lose their readers
// The GVRAM's graphics telemetry counters, {GR, GT, EG, PW}, and its walk pulses
// (GW/GC). They come out of pc9821_memory_subsystem; the counters are formatted into the
// graphics record below and the walk pulses are counted into the perf record.
wire [127:0] gfx_stats;
wire gdc_access_page;   // the GVRAM access page, declared before its first reader below
wire         gvram_walk_start, gvram_walk_cycle;
// The EGC/GRCG operation pulses (ET/EU/GS) that come out of the same GVRAM block.
wire         gvram_egc_txn, gvram_egc_unit, gvram_grcg_store;
// The GRCG's, the EGC's and the PLAIN client's per-cycle ownership pulses, the raw half of the
// perf record's visible-region counters (GV/EV): pc9821_perf_msg gates them with the video
// domain's v_active, which lives in pc9821_gdc_text and is declared further down.
wire         gvram_gr_owned, gvram_eg_owned, gvram_pw_owned;
// The page-coincidence probe's two raw page bits (PC/SP/AP): the access page the
// CPU/GRCG/EGC writes and the page the scanout's line fetch is latched on. pc9821_perf_msg
// counts the cycles a GVRAM store is in flight while the two are EQUAL (PC) and reports both
// as status fields (SP/AP). The store-in-flight arm is the union of all three owners above:
// the GRCG's alone would make the probe blind to exactly the shape Farland Story draws with
// (see the arbiter's dbg_pw_owned).
wire         gvram_access_page, gvram_scan_page_q;
/* verilator lint_on UNUSEDSIGNAL */
// The graphics GDC's draw-engine visit (the GDC2 WRITE slice): pc9821_gdc2's WRITE path
// takes its turn on the GVRAM's CPU-side port share inside the memory subsystem, so
// its writes travel the same GRCG/EGC tile path the machine routes them through.
wire         gdc_mem_valid, gdc_mem_ready, gdc_mem_write;
wire         gdc_mem_route_egc, gdc_mem_route_grcg, gdc_mem_page;
wire  [1:0]  gdc_mem_plane;
wire [14:0]  gdc_mem_offset;
wire [31:0]  gdc_mem_din, gdc_mem_rdata;
wire  [3:0]  gdc_mem_be;
wire         gdc_mem_resp;
// The PEGC view state from pc9821_crtc (the FF2 num-0x10 and dat-0x68 latches)
// and the packed scanout's outputs (row 3), declared before their first readers.
wire         gdc_pegc_256, gdc_pegc_256e;
// GDC2's START latch AND the slave SYNC window: the compositor's grph_disp, and the GVRAM
// arbiter's graphics-line level (its Xe10 store table), declared before both readers.
wire        gdc_gfx_grph_on;
wire  [7:0]  peg_packed_idx;
wire         peg_line_sel, peg_line_ready;

pc9821_memory_subsystem #(.SYS_CLOCK_HZ(SYS_FREQ), .GATHER_K(GATHER_K)) memory (
    .clk(clk_sys), .reset(reset), .hps_apply_reset(hps_apply_reset), .top_bank(top_bank),
    .ems_state(ems_state),
    .ide_rom_enable(ide_rom_enable),
    .d8_bank(d8_bank),
    .ide_ram_gate(ide_ram_gate),
    .bios_ram_gate(bios_ram_gate),
    .top_shadow_en(top_shadow_en),
    .soft_reboot(soft_reboot),
    .win0_sel(win0_sel),
    .win0_sel_moved(win0_sel_moved),
    .sys16m_en(sys16m_en),
    // The PEGC MMIO view select (pc9821_crtc's mode2_256col): with it up the
    // 0xE0000 window is the PEGC register file and the packed windows replace the
    // planar ones.
    .pegc_256(gdc_pegc_256), .pegc_256e(gdc_pegc_256e), .scan_dot(gdc_pix_dot[2:0]),
    // The 16-colour select (pc9821_crtc's mode2_16color, the 0x9A0 query's index 4 bit,
    // gdc_ff2_state[3]): the E plane at 0xE0000 is mapped only with it set.
    .mode2_16color(gdc_ff2_state[3]),
    .scan_dot_ce(pixel_ce), .scan_dot_act(gdc_pix_h_active),
    .pack_base(pack_base), .guest_ram_bytes(guest_ram_bytes),
    // The uPD71071's bus-master port: a floppy READ stores into memory and owes no response,
    // a floppy WRITE reads memory and is answered on dma_resp_valid/dma_dout (see the
    // subsystem's port comment). dma_valid is
    // the back-pressured presentation: a WRITE byte is withdrawn from the
    // subsystem while the bridge still holds a snoop for the CPU.
    .dma_addr(dma_mem_addr), .dma_addr_nx(dma_mem_addr_nx), .dma_load(dma_mem_load), .dma_din(dma_mem_din), .dma_be(dma_mem_be),
    .dma_valid(dma_mem_req_pres), .dma_write(dma_mem_we),
    .dma_ready(dma_mem_ready), .dma_dout(dma_mem_dout),
    .dma_resp_valid(dma_mem_resp_valid), .dma_snoop_addr(dma_snoop_addr),
    .gvram_access_page(gdc_access_page),
    .grcg_we(grcg_port_we), .grcg_addr(device_io_addr[7:0]),
    .grcg_din(device_io_din), .grcg_expand(mem_grcg_expand),
    .grcg_expand_nx(mem_grcg_expand_nx),
    // The EGC is ON, gated by the GDC's own enable (FF2 num 2 AND 0x7C bit 7) exactly
    // as the machine wires it. The EGC issues column accesses on the GVRAM port, so the
    // GRCG can never re-expand its writes as tile writes.
    .egc_enable(gdc_egc_mem_gate),
    // The nine EGC register inputs come from pc9821_iobus and are the SAME wires the
    // iobus instance drives with the egc_reset() power-up values.
    .egc_access(egc_access), .egc_fgbg(egc_fgbg), .egc_ope(egc_ope),
    .egc_fg(egc_fg), .egc_mask(egc_mask), .egc_bg(egc_bg),
    .egc_sft(egc_sft), .egc_leng(egc_leng), .egc_shift_we(egc_shift_we),
    // The graphics GDC's WRITE engine (the GDC2 WRITE slice) draws on the same port share.
    .gdc_mem_valid(gdc_mem_valid), .gdc_mem_ready(gdc_mem_ready),
    .gdc_mem_write(gdc_mem_write),
    .gdc_mem_route_egc(gdc_mem_route_egc),
    .gdc_mem_route_grcg(gdc_mem_route_grcg),
    .gdc_mem_page(gdc_mem_page), .gdc_mem_plane(gdc_mem_plane),
    .gdc_mem_offset(gdc_mem_offset), .gdc_mem_din(gdc_mem_din),
    .gdc_mem_be(gdc_mem_be),
    .gdc_mem_resp(gdc_mem_resp), .gdc_mem_rdata(gdc_mem_rdata),
    // gdc_disp is pc9821_crtc's DISP output, MODE FF1 bit 7 (the display
    // enable): the scanout fetch follows the DISP
    // bit alone, as NP2kai gates the graphics plane on `gdc.mode1 & 0x80`.
    .scan_enable(gdc_disp),
    // The OSD I/O timing field's GVRAM half (pc9821_gvram_arb's Xe10 store table): the same
    // level the iobus reads, and the graphics GDC's fetch window that table's RMW row keys on.
    .gvram_timing_xe10(io_timing_xe10),
    .gvram_gfx_scan_on(gdc_gfx_grph_on),
    .scan_line_tick(gvram_scan_line_tick),
    .scan_page(gdc_gfx_line_addr[15]),
    .scan_line_base(gdc_gfx_line_addr[14:0]),
    .scan_walk_page(gdc_gfx_walk_page),
    .gfx_odd_line(gdc_gfx_odd_line),
    .line_rd_addr(gvram_line_rd_addr), .line_rd_sel(gvram_line_rd_sel),
    .line_data(gvram_line_data), .line_sel(gvram_line_sel),
    .line_ready(gvram_line_ready),
    .peg_packed_idx(peg_packed_idx), .peg_line_sel(peg_line_sel),
    .peg_line_ready(peg_line_ready),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_wait(ioctl_wait), .rom_ready(rom_ready), .load_error(load_error),
    .cpu_run(cpu_run), .pack_load_hold(pack_load_hold),
    .font_addr(font_addr), .font_data(font_data),
    .font_we(font_we),
    .cpu_addr({z_addr, 2'b00}), .cpu_din(z_dout),
    .cpu_dout(mem_cpu_dout),
    .cpu_be(z_be), .cpu_burstcount(z_burstcount), .cpu_line_read(z_line_read),
    .cpu_valid(cpu_mem_valid), .cpu_write(z_write), .cpu_ready(mem_cpu_ready),
    .cpu_resp_valid(mem_cpu_resp_valid),
    .tram_addr(tram_addr), .tram_din(tram_din), .tram_we(tram_we),
    .tram_dout(tram_dout),
    .cg_win_byte_sel(cg_win_byte_sel), .cg_win_rd(cg_win_rd),
    .cg_win_dout(cg_win_dout), .cg_win_din(cg_win_din), .cg_win_we(cg_win_we),
    .cg_win_byte_hold(cg_win_byte_hold),
    .font_req_addr(font_req_addr), .font_req(font_req),
    .font_word_valid(font_word_valid), .font_word_data(font_word_data),
    .fmem_addr(ext_mem1_addr), .fmem_din(ext_mem1_din),
    .fmem_valid(ext_mem1_valid), .fmem_write(ext_mem1_write),
    .fmem_be(ext_mem1_be), .fmem_burstcount(ext_mem1_burstcount),
    .fmem_ready(ext_mem1_ready), .fmem_dout(ext_mem1_dout),
    .fmem_resp_valid(ext_mem1_resp_valid),
    .pmem_addr(ext_mem3_addr), .pmem_din(ext_mem3_din),
    .pmem_valid(ext_mem3_valid), .pmem_write(ext_mem3_write),
    .pmem_be(ext_mem3_be), .pmem_burstcount(ext_mem3_burstcount),
    .pmem_ready(ext_mem3_ready), .pmem_dout(ext_mem3_dout),
    .pmem_resp_valid(ext_mem3_resp_valid),
    .mem_addr(sub_mem_addr), .mem_din(sub_mem_din), .mem_din_hi(sub_mem_din_hi),
    .mem_gath(sub_mem_gath), .mem_gath_extra(sub_mem_gath_extra),
    .sdram_size(sdram_size),
    .mem_dout(sub_mem_dout),
    .mem_be(sub_mem_be),
    .mem_burstcount(sub_mem_burstcount),
    .mem_valid(sub_mem_valid), .mem_write(sub_mem_write),
    .mem_ready(sub_mem_ready), .mem_resp_valid(sub_mem_resp_valid),
    .dbg_gfx_stats(gfx_stats),
    .dbg_walk_start(gvram_walk_start), .dbg_walk_cycle(gvram_walk_cycle),
    .dbg_egc_txn(gvram_egc_txn), .dbg_egc_unit(gvram_egc_unit),
    .dbg_grcg_store(gvram_grcg_store),
    .dbg_gr_owned(gvram_gr_owned), .dbg_eg_owned(gvram_eg_owned),
    .dbg_pw_owned(gvram_pw_owned),
    .dbg_access_page(gvram_access_page), .dbg_scan_page_q(gvram_scan_page_q)
);

// The backend bus passes straight through to the SDRAM/legacy-memory ports. The
// GRCG is a client of the GVRAM block inside the subsystem, not a transformer on
// this bus.
assign ext_mem0_addr       = sub_mem_addr;
assign ext_mem0_din        = sub_mem_din;
assign ext_mem0_din_hi     = sub_mem_din_hi;
assign ext_mem0_gath       = sub_mem_gath;
assign ext_mem0_gath_extra = sub_mem_gath_extra;
assign ext_mem0_be         = sub_mem_be;
assign ext_mem0_burstcount = sub_mem_burstcount;
assign ext_mem0_valid      = sub_mem_valid;
assign ext_mem0_write      = sub_mem_write;
assign sub_mem_dout            = ext_mem0_dout;
assign sub_mem_resp_valid      = ext_mem0_resp_valid;
assign sub_mem_ready           = ext_mem0_ready;
// There is no 128-bit line response (the beat-uniform fill, trade-candidates T22):
// pc9821_memory_subsystem splits every line fill into four word beats at its own
// boundary and the z486 builds only its beat fill path.

// The video domain is clk_sys gated by pixel_ce: one dot per enable, at exactly 400/19 MHz
// (pc9821_dot_ce, below, carries the rate's provenance). video_ce carries that enable to the top
// level, where pc9821_video_out moves each dot into the video clock domain.

// One decode for the whole device bus. It lives in pc9821_device_select.sv, which documents
// the alias's equality form and the exhaustive sweep that holds it, and it is INSTANTIATED
// INSIDE pc9821_iobus: the same decode also produces the
// device-bus CLAIM (`dev_bus_cs`), which is what the I/O fabric's own FSM needs, so the claim and
// the chip selects are one product of one module instead of two hand-kept lists. The module owns
// every claim on the bus, including: the second IDE task-file mirror 0x0740-0x074E, the
// PC-9801-86's two devices, the OPNA's four ports and the 86-PCM block's seven, and the
// PC-9801-118's game port at 0x1480-0x1487. All of them must be claimed there because gdc_cs is
// the complement of the whole list. The selects arrive here as the iobus's outputs.
wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
     ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs;   // gdc_cs is declared above its first reader
wire [7:0] cal_io_dout, cal_mode_dout, cal_tick_dout;
// Only the GDC's I/O reads come out of block RAM (its CG and ANK arrays), one
// cycle behind the address, so it is the only device that asks the I/O bus for
// an extra read cycle. Every other device presents its data in the strobe cycle,
// and several act on that strobe, so they must not be delayed: the ATA advances
// its PIO byte pointer on it and the PIT gates its output on it. The OPNA's
// chip output is registered; the 86-PCM block's reads are its register file, so
// it does not ask (its io_rd_wait is left unconnected below).
wire opna_rd_wait, opna_irq, pcm86_irq;
assign device_rd_wait = gdc_cs || opna_rd_wait;   // declared above the iobus instance
// The write back-pressure: the OPNA register queue and the 86-PCM 0xA46C FIFO say
// "not now" through these, and pc9821_iobus stalls the guest's I/O write instead
// of letting either buffer silently drop it. The OPNA's own term is
// op_sel-wide (most of the address space), so it takes the opna_cs qualifier
// here; the pcm86 term is already window-decoded to 0xA468-0xA46F inside
// pc9821_pcm86 (so a word/dword OUT straddling 0xA46C stalls before its first
// lane), and re-qualifying it with pcm_cs would exclude exactly those odd first
// lanes -- its window is the bound.
wire opna_wr_wait, pcm86_wr_wait;
assign device_wr_wait = (opna_cs && opna_wr_wait) || pcm86_wr_wait;
// A device that needs MORE than the one extra cycle holds the bus. Two do:
//   * the CG block: a JIS read of port 0xA9 or the 0xA4000 window waits until its SDRAM
//     glyph burst lands; the qualification keeps it to the CG pattern port.
//   * the OPNA: a status read (0x188/0x18C) waits while a queued flag-class write (timer
//     control, IRQ enables, ADPCM-B control and flag control) has not reached the chip,
//     so the guest never reads a flag it has already reset (pc9821_opna flg_pend). Its
//     hold is low whenever no such write is queued.
wire opna_rd_hold;
wire cg_port_rd    = gdc_cs && (device_io_addr[7:0] == 8'hA9);
assign device_rd_hold = (cg_port_rd && cg_rd_hold) ||
                        (opna_cs && opna_rd_hold);   // declared above the iobus instance
wire [7:0] cd_io_dout;
wire       cd_io_own, cd_irq;
wire [7:0] cd_log_byte;
wire       cd_log_we;
wire       cd_log_accept;   // the debug mux's grant of the CD log's byte (else the FIFO's)
wire [7:0] interrupt_io_dout, kbd_io_dout, ata_io_dout, opna_io_dout, pcm86_io_dout,
           gameport_io_dout, mpu_io_dout, sdph_io_dout;
// the wide board sum: clamped FM+ADPCM junction + AC-coupled SSG<<2 + PCM86 (F1: no join clamp)
wire signed [19:0] opna_snd_l, opna_snd_r;
wire signed [15:0] pcm86_snd_l, pcm86_snd_r;
// Rhythm ROM pack-loader write port (pc9821_rhythm_loader -> pc9821_opna ->
// RHYTHM_ROM). Empty without a user-supplied image; see
// src/opna/rhythm_rom/RHYTHM_ROM.v and tools/build_pack.py.
wire        rhythm_we;
wire [11:0] rhythm_waddr;
wire [15:0] rhythm_wdata;
/* verilator lint_off UNUSEDSIGNAL */   // out0 is the IRQ-source bit inside pc9821_interrupts
wire pit_out0, kbd_irq, ata_irq;
/* verilator lint_on UNUSEDSIGNAL */
// PIT channel 1: the beeper's tone, a square wave at 2.4576 MHz / divisor. Channel 2 is
// the RS-232C baud generator, not the beeper (see pc9821_interrupts.sv).
wire pit_out1;
/* verilator lint_off UNUSEDSIGNAL */   // pit_out2 is the RS-232C baud clock: a real machine
// signal this core does not yet consume (no serial port is modelled). Kept exported so the
// interrupts module's port list stays symmetric, and waived rather than silently unused.
wire pit_out2;
/* verilator lint_on UNUSEDSIGNAL */
// 0x20 is write-only (the machine reads 0xFF there); 0x128 returns the enable, the tick flag and the rate (pc9821_calendar).
assign cal_io_dout = (device_io_addr == 16'h0022) ? cal_mode_dout :
                     (device_io_addr == 16'h0128) ? cal_tick_dout : 8'hFF;
// 0x0433 is the IDE interface's per-bank interrupt-pending port (pc9821_ata's read arm says
// where each bit comes from): pc9821_ata answers its own drives' INTRQs, and the CD-ROM, bank 1's
// master, adds its INTRQ as bit 1 (qemu-pc98 hw/ide/pc98-ide.c:203 `ret = s->irq_levels & 0x03;`).
wire [7:0] ide_433_cd = {6'd0, cd_irq && (device_io_addr == 16'h0433), 1'b0};
assign device_io_dout = interrupt_cs ? interrupt_io_dout :
                        kbd_cs       ? kbd_io_dout       :
                        ata_cs       ? (cd_io_own ? cd_io_dout : (ata_io_dout | ide_433_cd)) :
                        cal_cs       ? cal_io_dout       :
                        opna_cs      ? opna_io_dout      :
                        pcm_cs       ? pcm86_io_dout     :
                        gameport_cs  ? gameport_io_dout  :
                        mpu_cs       ? mpu_io_dout       :
                        sdph_cs      ? sdph_io_dout      : gdc_io_dout;

// ---------------------------------------------------------------
// The run-time SDRAM_CLK phase instrument (test builds only)
// ---------------------------------------------------------------
// pc9821_sdram_phase_ctl.sv says what it is. Its step handshake leaves on sdph_step_req/up and its
// answer arrives on sdph_step_ack/fault from the top level's scan-clock engine.
generate
if (SDRAM_PHASE_DYN) begin : g_sdph
    pc9821_sdram_phase_ctl #(.CLOCK_RATE_HZ(SYS_FREQ)) u_sdph (
        .clk(clk_sys), .reset(reset),
        .cs(sdph_cs), .addr(device_io_addr), .wr(device_io_wr),
        .din(device_io_din), .dout(sdph_io_dout),
        .step_req(sdph_step_req), .step_up(sdph_step_up),
        .step_ack_async(sdph_step_ack), .fault_async(sdph_fault)
    );
end else begin : g_no_sdph
    assign sdph_io_dout  = 8'hFF;
    assign sdph_step_req = 1'b0;
    assign sdph_step_up  = 1'b0;
end
endgenerate

// ---------------------------------------------------------------
// Roland MPU-PC98II (MIDI)
// ---------------------------------------------------------------
// The C-bus MIDI card at 0xE0D0/0xE0D2, present only when MPU_EN built it. Its serial output is
// the framework's MIDI-out path: z486_mister.sv already selects UART_TXD between the debug
// UART and this port on the OSD's UART Mode (`uart_midi_mode`), so nothing else has to change
// for MidiLink to carry the stream. Its IRQ is the master PIC's IRQ6 - the card's own default
// (NP2kai cbus/mpu98ii.c:98's table indexed by the 0x82 option, pccore.c:873) - which is
// master_aux_irq's bit 3 (pc9821_interrupts's `ir_in({slave_int, master_aux_irq, ...})`:
// [6] = IRQ6). With MPU_EN 0 both are constants and the aux lines stay the 4'b0000 they were.
//
// PRESENT ONLY IN MIDI MODE. The card exists for the guest only while the OSD's UART mode is
// MIDI (mpu_present): otherwise software that finds an MPU would send its music to a MIDI line
// nobody listens to instead of the FM it falls back to. Absent, the card's ports read 0xFF, the
// open-bus value the same ports read with MPU_EN 0, and the card is HELD IN RESET: that is what
// gates its IRQ6 (the reset empties the response queue the IRQ follows) and drops writes (the
// reset branch outranks them), and it brings the card back in its power-on state, so a mode
// change in the middle of a guest's transaction cannot leave it wedged. Only the read data needs
// its own gate, since a card in reset still drives its idle 0x80. The device decode itself is not
// touched (mpu_cs still claims 0xE0D0/0xE0D2 whenever MPU_EN built the card), so the gate adds
// nothing to the device-select path; the presence level is registered once here, and an access
// to the absent card takes the same bus time as the MPU_EN 0 open-bus read
// (tb_pc9821_mpu_system measures both).
wire mpu_irq;
wire mpu_uart_tx_int;
generate
if (MPU_EN) begin : g_mpu
    reg  mpu_present_r;   // follows mpu_present one clk later; no power-up value needed
    always @(posedge clk_sys) mpu_present_r <= mpu_present;
    wire [7:0] mpu_card_dout;
    pc9821_mpu #(.SYS_CLOCK_HZ(SYS_FREQ)) u_mpu (
        .clk(clk_sys), .reset(reset || !mpu_present_r),
        .cs(mpu_cs), .addr(device_io_addr),
        .wr(device_io_wr), .rd(device_io_rd),
        .din(device_io_din), .dout(mpu_card_dout),
        .uart_tx(mpu_uart_tx_int), .irq(mpu_irq)
    );
    assign mpu_io_dout = mpu_present_r ? mpu_card_dout : 8'hFF;
end else begin : g_no_mpu
    assign mpu_io_dout    = 8'hFF;
    assign mpu_uart_tx_int = 1'b1;      // the line's idle MARK, as before the card existed
    assign mpu_irq        = 1'b0;
end
endgenerate

// ---------------------------------------------------------------
// Serial calendar (uPD4990A / uPD4993A)
// ---------------------------------------------------------------
// The counters are a battery-backed device register, so they come from the
// framework RTC -- which the framework sends once at core start -- and free-run
// locally afterwards. This is not the guest-state pre-seeding we refuse to
// copy: the guest's own INT 1Ch builds its representation from this.
reg rtc_loaded;
always @(posedge clk_sys)
  if (reset || !cpu_run) rtc_loaded <= 1'b0;
  else rtc_loaded <= 1'b1;

pc9821_calendar #(.SYS_CLOCK_HZ(SYS_FREQ)) calendar (
    .clk(clk_sys), .rst_n(!(reset || !cpu_run)),
    .rtc_bcd(rtc), .rtc_load(cpu_run && !rtc_loaded),
    .cmd_we (device_io_wr && cal_cs && (device_io_addr == 16'h0020)),
    .cmd_din(device_io_din),
    .mode_we (device_io_wr && cal_cs && (device_io_addr == 16'h0022)),
    .mode_din(device_io_din),
    .mode_dout(cal_mode_dout),
    .tick_we (device_io_wr && cal_cs && (device_io_addr == 16'h0128)),
    .tick_din(device_io_din),
    .tick_rd (device_io_rd && cal_cs && (device_io_addr == 16'h0128)),
    .tick_dout(cal_tick_dout),
    .cdat(cal_cdat),
    .irq(cal_irq));

// ---------------------------------------------------------------
// PC-9801-86 sound (YM2608 OPNA)
// ---------------------------------------------------------------
// The card's glue: base ports 0x188/0x18A, extension 0x18C/0x18E gated by 0xA460 bit 0;
// stereo into z486_mister.sv's mixer (sample_86_l/r, vol_voice), timer IRQ to the 8259's
// slave IR4.
//
// IRQ line: the factory-default DIP setting INT5 is IRQ12 (the slave 8259's IR4, vector
// 0x14), and that is the level PMD selects from PSG register 0x0E's readback (bits 7:6 =
// 11 -> level 12). Both timers' IRQ enables (0x27 bits 2-3) are clear out of reset, so
// the line is benign until a driver raises one.
//
// The rhythm image rides the pack download, the one stream carrying the user's YM2608 ADPCM-A
// samples (pack offset 0x49000), so the samples need no SDRAM read. Reset is the system reset
// alone, not gated by `!cpu_run` as the chip instances are: the load happens while the CPU is
// held.
pc9821_rhythm_loader rhythm_loader (
    .clk(clk_sys), .reset(reset),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .we(rhythm_we), .waddr(rhythm_waddr), .wdata(rhythm_wdata)
);

// The game port's six switch lines, read by both the OPNA's joystick register and the
// gameport module; declared before the OPNA instance, its first reader.
wire [5:0] gameport_switch_lines;

pc9821_opna #(.SYS_CLOCK_HZ(SYS_FREQ)) sound (
    .clk(clk_sys), .reset(reset || !cpu_run),
    .io_addr(device_io_addr),
    .io_wr(device_io_wr && opna_cs),
    .io_rd(device_io_rd && opna_cs),
    .io_din(device_io_din),
    .io_dout(opna_io_dout),
    .io_rd_wait(opna_rd_wait),
    .io_rd_hold(opna_rd_hold),
    .io_wr_wait(opna_wr_wait),
    .extend(sound_extend),
    // The card's own joystick read (register 0x0E) is the GAME PORT's switch lines, not
    // the OPNA's: both are the one 9-pin connector. See pc9821_gameport.
    .joystick(gameport_switch_lines),
    .snd_l(opna_snd_l), .snd_r(opna_snd_r),
    .irq(opna_irq),
    .rhythm_we(rhythm_we), .rhythm_waddr(rhythm_waddr),
    .rhythm_wdata(rhythm_wdata)
);

// ---------------------------------------------------------------
// The 9-pin game port (PC-9801-118, 0x1480-0x1487, only with GAMEPORT_118)
// ---------------------------------------------------------------
// The connector the whole joystick story is about: the axis one-shots above, read with the
// IBM protocol, and the six switch lines the sound board's own joystick register answers.
// The OSD inputs are the system's own ports (z486_mister.sv maps joystick_0/1 and the two
// analog words onto them). It is the card's only device that reads the guest's inputs.

pc9821_gameport #(.SYS_CLOCK_HZ(SYS_FREQ)) gameport (
    .clk(clk_sys), .reset(reset || !cpu_run),
    .io_wr(device_io_wr && gameport_cs),
    .io_rd(device_io_rd && gameport_cs),
    .io_dout(gameport_io_dout),
    .dis(joystick_dis), .mode(joystick_mode), .timed(joystick_timed),
    .dig_1(joystick_dig_1), .dig_2(joystick_dig_2),
    .ana_1(joystick_ana_1), .ana_2(joystick_ana_2),
    .switch_lines(gameport_switch_lines)
);

// ---------------------------------------------------------------
// PC-9801-86 86-PCM (the other device on the same card)
// ---------------------------------------------------------------
// Its seven even ports 0xA462-0xA46E, a 32 KiB sample buffer and the drain
// engine that plays it. Its interrupt is
// a level the guest clears at 0xA468 bit 4, and on the card ONE strap feeds the
// OPNA's timers and this block, so both sources share the same 8259 input
// (pc9821_irq_share, below) rather than being given separate numbers -- an implementation that
// straps them differently is wrong. The line itself is IRQ12 and is shared by
// this block; moving the strap moves both.
pc9821_pcm86 #(.SYS_CLOCK_HZ(SYS_FREQ)) pcm86 (
    .clk(clk_sys), .reset(reset || !cpu_run),
    .io_addr(device_io_addr),
    .io_wr(device_io_wr && pcm_cs),
    .io_rd(device_io_rd && pcm_cs),
    .io_din(device_io_din),
    .io_dout(pcm86_io_dout),
    /* verilator lint_off PINCONNECTEMPTY */   // reads are answered in the strobe cycle
    .io_rd_wait(),
    /* verilator lint_on PINCONNECTEMPTY */
    .io_wr_wait(pcm86_wr_wait),
    .snd_l(pcm86_snd_l), .snd_r(pcm86_snd_r),
    .irq(pcm86_irq),
    // The logical byte count is a bench instrument only; the card exposes it
    // through 0xA466's two status bits and nothing else.
    /* verilator lint_off PINCONNECTEMPTY */   // bench instrument only, see the note above
    .dbg_count(),
    /* verilator lint_on PINCONNECTEMPTY */
    // The 32 KiB sample buffer lives in SDRAM, on the controller's third port (see
    // src/pcm86/pc9821_pcm86_buf.sv). Its base sits above the firmware pack and the GVRAM
    // reserve the SDRAM module must already cover: pack_base + PACK_BYTES + 256 KiB.
    .buf_base(pack_base + 32'h0014_0000),
    .sdram_valid(ext_mem2_valid), .sdram_ready(ext_mem2_ready),
    .sdram_write(ext_mem2_write), .sdram_addr(ext_mem2_addr),
    .sdram_din(ext_mem2_din), .sdram_dout(ext_mem2_dout),
    .sdram_resp_valid(ext_mem2_resp_valid), .sdram_be(ext_mem2_be),
    .sdram_burstcount(ext_mem2_burstcount)
);

// The INT5 strap's two sources on one 8259 input: every OPNA timer event and every 86-PCM
// event is its own request even while the other source holds the line (see the module).
wire int5_irq;
pc9821_irq_share int5_share (
    .clk(clk_sys), .reset(reset || !cpu_run),
    .irq_a(opna_irq), .irq_b(pcm86_irq),
    .irq(int5_irq)
);

// Debug observability wires from the interrupts and keyboard instances below. Declared
// before those instances, which are their first readers.
/* verilator lint_off UNUSEDSIGNAL */   // PERF_LOG_EN=0: the debug taps here lose their only reader
wire [7:0] kbd_dbg_events, kbd_dbg_delivered, kbd_dbg_rd_data, kbd_dbg_wr_ctrl;
wire       kbd_dbg_rts, kbd_dbg_rx_en;
wire [7:0] kbd_dbg_last_del, kbd_dbg_ctrl0, kbd_dbg_ctrl1;
wire [7:0] irq_dbg_imr, irq_dbg_irr, irq_dbg_isr;
wire [7:0] irq_dbg_s_imr, irq_dbg_s_isr;
/* verilator lint_on UNUSEDSIGNAL */

pc9821_interrupts #(.SYS_CLOCK_HZ(SYS_FREQ)) interrupts (
    .clk(clk_sys), .reset_n(!(reset || !cpu_run)),
    .io_wr(device_io_wr), .io_rd(device_io_rd),
    .io_addr(device_io_addr), .io_din(device_io_din),
    .master_cs(pic_master_cs), .slave_cs(pic_slave_cs), .pit_cs(pit_cs),
    .io_dout(interrupt_io_dout), .keyboard_irq(kbd_irq),
    .dbg_imr(irq_dbg_imr), .dbg_irr(irq_dbg_irr), .dbg_isr(irq_dbg_isr),
    .dbg_s_imr(irq_dbg_s_imr), .dbg_s_isr(irq_dbg_s_isr),
    // master_aux_irq is IRQ3..IRQ6 (pc9821_interrupts.sv:36 (input wire [3:0] master_aux_irq, // IRQ3..IRQ6)), and until the MPU-PC98II landed
    // no device here used those lines: the sound card's timer IRQ moved to the slave, where the
    // factory-default INT5 = IRQ12 lives (see below). The MPU is the first user, on the card's
    // own default IRQ6 = bit 3, and with MPU_EN 0 the vector is the 4'b0000 it was.
    .vsync_irq(gdc_vsync_irq), .master_aux_irq({mpu_irq, 3'b000}),
    // slave_irq is EIGHT bits (IRQ8..IRQ15): bit 1 = IRQ9 (the IDE ROM), bit 2 = IRQ10 (the
    // FDC when the 0x00BE strap selects its 2DD port window - the one controller's
    // completion on the other of its two IRQ lines), bit 3 = IRQ11
    // (the FDC - the BIOS installs its FDC ISR at IVT vector 0x13), bit 4 = IRQ12 (the
    // sound card's factory-default INT5), bit 5 = IRQ13 (the BUS MOUSE's periodic
    // event - mouseint's pic_setirq(0x0d), io/mouseif.c:135; the same IRQ13 the
    // qemu-pc98 board wires it to, hw/i386/pc98.c:422-423), bit 7 = IRQ15 (the
    // calendar tick). Keep the width visible: 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 = 8.
    .slave_irq({cal_irq, 1'b0, mouse_irq, int5_irq, fdc_irq,
                fdc_irq10, ata_irq | cd_irq, 1'b0}),
    // THE STROBE IS THE CPU'S OWN: z486's inta output, NOT the bridge's masked
    // p_inta. During an accept held for a disabled CPU cycle the bridge drops p_inta, so a
    // flag keyed on it would clear without the CPU ever releasing the strobe - the
    // one-answer-per-asserted-strobe invariant (pc9821_inta_bridge's R5/R6/R8 checks)
    // would stop being provable. zc_inta is a CPU-domain LEVEL held for a whole CPU cycle,
    // so sampling it on clk_sys is exactly the level the checks assume.
    .cpu_intr(z_intr), .cpu_inta(zc_inta), .cpu_inta_din(inta_din),
    .cpu_inta_ready(inta_ready), .pit_out0(pit_out0), .pit_out1(pit_out1),
    .pit_out2(pit_out2)
);

pc9821_kbd #(.SYS_CLOCK_HZ(SYS_FREQ)) keyboard (
    .clk(clk_sys), .rst_n(!(reset || !cpu_run)), .cs(kbd_cs),
    .a0(device_io_addr[1]), .wr(device_io_wr), .rd(device_io_rd),
    .din(device_io_din), .dout(kbd_io_dout), .irq(kbd_irq),
    .ps2_key(ps2_key),
    .layout_jis(kbd_layout_jis),
    .led_status(kbd_led_status),
    .dbg_events(kbd_dbg_events), .dbg_delivered(kbd_dbg_delivered),
    .dbg_rd_data(kbd_dbg_rd_data), .dbg_wr_ctrl(kbd_dbg_wr_ctrl),
    .dbg_rts(kbd_dbg_rts), .dbg_rx_en(kbd_dbg_rx_en),
    .dbg_last_del(kbd_dbg_last_del), .dbg_ctrl0(kbd_dbg_ctrl0),
    .dbg_ctrl1(kbd_dbg_ctrl1)
);

wire hdd_mounted, hdd_readonly;
/* verilator lint_off UNUSEDSIGNAL */   // PERF_LOG_EN=0: the compiled-out watchdog is its only reader
wire hdd_busy;
/* verilator lint_on UNUSEDSIGNAL */
wire [31:0] hdd_capacity;
wire ata_block_read, ata_block_write, ata_block_done, ata_block_error;
wire [31:0] ata_block_lba;
wire ata_buf_we;
wire [7:0] ata_buf_addr;
wire [15:0] ata_buf_data;
wire [7:0] ata_buf_rd_addr;
wire [15:0] ata_buf_rd_data;
wire [31:0] hdd_sd_lba;
wire [5:0] hdd_sd_blk_cnt;
wire hdd_sd_rd, hdd_sd_wr;
// The HDI detector's seam to the shared engine: the drive's requests (its side of the
// pc9821_hdd_image instance below) and the engine's completions and word stream back.
wire        hdd_a_req_read, hdd_a_req_write;
wire [31:0] hdd_a_req_lba;
wire        hdd_a_req_window;
wire        hdd_a_req_done, hdd_a_req_error;
wire        hdd_a_buf_we;
wire [ 7:0] hdd_a_buf_addr;
wire [15:0] hdd_a_buf_data;
// The last completed HPS block transfer's cycles (HP): pc9821_block_io counts it and the
// watchdog record publishes it, because the per-block HPS round trip is the one term in the disk
// path that no bench models and no other telemetry field sees. Declared here, above its first use,
// so it cannot become an implicit 1-bit wire.
/* verilator lint_off UNUSEDSIGNAL */   // PERF_LOG_EN=0: the compiled-out watchdog is their only reader
wire [31:0] hdd_hps_cycles;
wire [7:0] ata_dbg_state;
wire [31:0] ata_dbg_cmd;
// The transfer context the stall record's ALB/ASE fields carry (pc9821_ata's
// dbg_lba/dbg_sec): the LBA of the transfer and {sector_count, error_reg}.
wire [31:0] ata_dbg_lba;
wire [15:0] ata_dbg_sec;
/* verilator lint_on UNUSEDSIGNAL */

// THE IDE LAYOUT AT ITS DEFAULT: the hard disk (hps_io slot 0) is ALWAYS bank
// 0's master (IDE unit 0) and the CD-ROM, when built, bank 1's master (unit 2); with the CD left
// out bank 1 is empty unless the second disk is mounted. That is the stock CD-equipped Xe10's layout and NP2kai's default
// (HDD at unit 0, CD at unit 2); the measured Xe10 has its disk on bank 1 only because a CF card
// sits in its CD connector. Port 0xF0 bit 5 reports the disk (so the ITF's IDE drive bitmap
// includes unit 0 and the IDE ROM probes and boots it) and bit 6 the CD drive; neither moves with
// a CD mount or eject.
// BANK 1'S MASTER IS THE OSD'S CHOICE (`ide_bank1_hdd`): the CD-ROM (the default, above) or the
// second hard disk. With the disk the CD drive is absent from the bus (no write reaches it, see
// its instance) and bank 1 is the disk's: pc9821_ata serves it as its
// second bank, and port 0xF0 bit 6 follows that disk's image as bit 5 follows the first disk's.
// The Xe10 IDE ROM then registers the disk on bank 1 by IDENTIFY (BANK3@0x0A96) as DA/UA 0x81
// behind bank 0's disk, or 0x80 alone. With the CD selected the second image is invisible.
/* verilator lint_off PROCASSINIT */   // the initialiser is the register's power-up value
reg ide_bank1_hdd_eff = 1'b0;           // power-on default: the CD-ROM, the stock layout
/* verilator lint_on PROCASSINIT */
always @(posedge clk_sys) if (reset || !cpu_run) ide_bank1_hdd_eff <= ide_bank1_hdd;
wire hdd2_mounted, hdd2_readonly;
wire [31:0] hdd2_capacity;
wire ata_block_unit, hdd_a_req_unit;
wire ata_mounted1 = ide_bank1_hdd_eff && hdd2_mounted;
assign ide_unit0_present = hdd_mounted;
// Bank 1's master is present: the second disk's image when it holds bank 1, else the CD drive
// (a drive on the cable whether or not a disc is in it).
assign ide_unit2_present = ide_bank1_hdd_eff ? hdd2_mounted : CDROM_EN;

// THE IDE DEVICES RESET ON A SOFTWARE REBOOT. The Xe10 IDE ROM accepts a drive only when its
// ERROR register reads the post-reset diagnostic 0x01 (pc9821_ata's reset arm); a reboot that left
// the task file as DOS's last command left it (ERROR 0x00) made the ROM's presence check reject
// the disk, and the re-POST looped on the floppy boot (the userdisk tier, an RBOOT from DOS: BANK3
// D800:0D7B read 0x0642 = 00 where the cold boot reads 01). NP2kai resets the IDE devices on its
// CPU reset for exactly this case (pccore.c `ideio_basereset(); // XXX: Win9x...`, whose devinit
// sets `drv->error = IDEERR_AMNF`), and QEMU's armed 0x534 is a machine reset. Only the reboot
// does it here, not out 0xF0: that reset is the protected-mode return's, which the machine's
// drives never see. The hdd images and their host transfers survive, as they do a platform reset.
wire ide_dev_rst_n = !(reset || !cpu_run || soft_reboot);
// The IDE devices' "command in progress" (BSY|DRQ) views, for the HDD access lamp below.
wire ata_xfer, cd_xfer;

pc9821_ata ata (
    .clk(clk_sys), .rst_n(ide_dev_rst_n),
    .io_rd(device_io_rd && ata_cs), .io_wr(device_io_wr && ata_cs),
    .io_addr(device_io_addr), .io_din(device_io_din), .io_dout(ata_io_dout),
    .mounted(hdd_mounted), .readonly(hdd_readonly), .capacity(hdd_capacity),
    .mounted1(ata_mounted1), .readonly1(hdd2_readonly), .capacity1(hdd2_capacity),
    .block_read(ata_block_read), .block_write(ata_block_write),
    .block_lba(ata_block_lba), .block_unit(ata_block_unit),
    .block_done(ata_block_done), .block_error(ata_block_error),
    .block_buf_we(ata_buf_we), .block_buf_addr(ata_buf_addr),
    .block_buf_data(ata_buf_data),
    .block_rd_addr(ata_buf_rd_addr), .block_rd_data(ata_buf_rd_data),
    .irq(ata_irq),
    .xfer(ata_xfer),
    .dbg_state(ata_dbg_state),
    .dbg_cmd(ata_dbg_cmd),
    .dbg_lba(ata_dbg_lba),
    .dbg_sec(ata_dbg_sec)
);

// ------------------------------------------------------------------ HDI image detection
// The ATA keeps its one-drive contract; this seam reads the mounted image's first sector
// before reporting ready and adds the HDI header's sector offset to every guest LBA. A raw
// image (or any header that does not validate) passes through with offset 0 and the file's
// own size, which is the behaviour this core had before HDI existed. The module's header
// states the format, the validation and why the offset survives a platform reset.
pc9821_hdd_image hdd_image (
    .clk(clk_sys), .rst_n(!reset),
    // Both disks' slots: the size is the pulsing slot's (one hps_io register at the top level).
    .img_mounted(img_mounted), .img_mounted1(hdd1_mounted), .img_readonly(img_readonly),
    .img_size(hdd1_mounted ? hdd1_size : img_size),
    .mounted(hdd_mounted), .readonly(hdd_readonly), .capacity(hdd_capacity),
    .mounted1(hdd2_mounted), .readonly1(hdd2_readonly), .capacity1(hdd2_capacity),
    .req_read(ata_block_read), .req_write(ata_block_write), .req_lba(ata_block_lba),
    .req_unit(ata_block_unit),
    .req_done(ata_block_done), .req_error(ata_block_error), .busy(hdd_busy),
    .buf_we(ata_buf_we), .buf_addr(ata_buf_addr), .buf_data(ata_buf_data),
    .a_req_read(hdd_a_req_read), .a_req_write(hdd_a_req_write), .a_req_lba(hdd_a_req_lba),
    .a_req_window(hdd_a_req_window), .a_req_unit(hdd_a_req_unit),
    .a_req_done(hdd_a_req_done), .a_req_error(hdd_a_req_error),
    .a_buf_we(hdd_a_buf_we), .a_buf_addr(hdd_a_buf_addr), .a_buf_data(hdd_a_buf_data)
);

// ------------------------------------------------------------------ the CD-ROM (CDROM_EN)
// pc9821_atapi is bank 1's master (the hard disk is bank 0's) and owns hps_io slot 4. Its
// task-file reads win the IDE read mux while it is the selected device (`cd_io_own`); its IRQ
// shares the IDE line (IRQ9) with the hard disks. The task file resets with the ATA (held until
// cpu_run); the medium and its host transfers are the slot's and survive a reset (the module's
// declarations say why).
// The one owner of hps_io's shared word bus (see the module): each consumer group below gets a
// private strobe that is high only while its own slot's ack is, so neither can see the other's
// words. The consumers keep their own ack gates as defence in depth.
wire        disk_buff_wr, cd_buff_wr;
wire [12:0] disk_buff_addr, cd_buff_addr;
wire [15:0] disk_buff_dout, cd_buff_dout;
pc9821_hps_slot_demux hps_demux (
    .sd_buff_wr(img_buff_wr), .sd_buff_addr(img_buff_addr), .sd_buff_dout(img_buff_din),
    .disk_ack(img_ack | fdd_ack | fdd1_ack | hdd1_ack), .cd_ack(cd_ack),
    .disk_buff_wr(disk_buff_wr), .disk_buff_addr(disk_buff_addr), .disk_buff_dout(disk_buff_dout),
    .cd_buff_wr(cd_buff_wr), .cd_buff_addr(cd_buff_addr), .cd_buff_dout(cd_buff_dout)
);
generate if (CDROM_EN) begin : g_cdrom
pc9821_atapi #(.AUDIO_EN(CDROM_AUDIO_EN), .LOG_EN(CDROM_LOG_EN && !PERF_LOG_EN),
               .LOG_CLK_HZ(SYS_FREQ)) atapi (
    .clk(clk_sys), .rst_n(ide_dev_rst_n),
    // ABSENT FROM THE BUS while bank 1 holds the second hard disk (ide_bank1_hdd_eff): no write
    // reaches it, so its own bank latch stays at its reset value 0 (the field changes only across
    // a platform reset, which resets this drive's task file too). Every read side effect, its
    // read ownership (`io_own`) and every interrupt it can raise (a command's completion) are
    // behind that latch, so the drive is not there for the guest at all.
    .io_rd(device_io_rd && ata_cs),
    .io_wr(device_io_wr && ata_cs && !ide_bank1_hdd_eff),
    .io_addr(device_io_addr), .io_din(device_io_din), .io_dout(cd_io_dout),
    .io_own(cd_io_own), .irq(cd_irq), .xfer(cd_xfer),
    .img_mounted(cd_mounted), .img_size(cd_size),
    .sd_lba(cd_lba), .sd_blk_cnt(cd_blk_cnt), .sd_rd(cd_rd), .sd_ack(cd_ack),
    .sd_buff_wr(cd_buff_wr), .sd_buff_addr(cd_buff_addr), .sd_buff_dout(cd_buff_dout),
    .cdda_req(cdda_req), .cdda_req4(cdda_req4), .cdda_played(cdda_played),
    .cdda_flush(cdda_flush), .cdda_wr(cdda_wr), .cdda_data(cdda_data),
    .log_byte(cd_log_byte), .log_we(cd_log_we), .log_accept(cd_log_accept)
);
end else begin : g_no_cdrom
assign cd_log_byte = 8'h00;
assign cd_log_we   = 1'b0;
assign cd_io_dout = 8'hFF;
assign cd_io_own  = 1'b0;
assign cd_irq     = 1'b0;
assign cd_xfer    = 1'b0;
assign cd_lba     = 32'd0;
assign cd_blk_cnt = 6'd0;
assign cd_rd      = 1'b0;
assign cdda_wr    = 1'b0;
assign cdda_flush = 1'b0;
assign cdda_data  = 32'd0;
// No CD: its slot pins and the CD-DA request have no reader.
/* verilator lint_off UNUSEDSIGNAL */
wire cd_unused = cd_mounted | (|cd_size) | cd_ack | cdda_req | cdda_req4 | cdda_played | cd_buff_wr | (|cd_buff_addr) | (|cd_buff_dout);
/* verilator lint_on UNUSEDSIGNAL */
end endgenerate

// ------------------------------------------------------------------ the access lamps
// Display only (see the module): the drives' data transfers with their images - the ATA's and
// the CD's `xfer`, the FDC's media data path (x_st of its dbg_state tap {IRQ, DRQ, st, x_st}) -
// each held on for 50 ms so a microsecond transfer is visible.
pc9821_disk_led #(.CLK_HZ(SYS_FREQ), .HOLD_MS(50)) disk_led (
    .clk(clk_sys), .reset(reset),
    .ata_xfer(ata_xfer), .cd_xfer(cd_xfer),
    .fdc_x_st(dbg_fdc_state[2:0]),
    .led_disk(led_disk), .led_fdd(led_fdd)
);

pc9821_block_share block_share (
    // Reset only with the core, NOT with cpu_run: the HPS mounts the image
    // (MGL delay ~1 s) before the ROM pack download finishes (~4 s), and
    // hps_io's img_mounted is a single-cycle pulse. Holding this block in
    // reset until cpu_run discarded that pulse, so the guest booted with no
    // disk on hardware while the benches - which mount after debug_bios_loaded
    // - still found it. The ATA stays held until cpu_run, so no request can be
    // issued before the CPU starts.
    .clk(clk_sys), .rst_n(!reset),

    // ---- slot 0: the hard disk (pc9821_ata) ----
    // The ATA reaches the engine through pc9821_hdd_image above (the HDI header detector):
    // the engine's A port speaks the detector's translated LBAs, and the detector gates the
    // probe's words away from the drive's sector buffer.
    .a_img_mounted(img_mounted), .a_img_readonly(img_readonly), .a_img_size(img_size),
    /* verilator lint_off PINCONNECTEMPTY */   // the A-side metadata and busy are the
    // detector's (it holds the guest-visible capacity/readonly and publishes busy)
    .a_mounted(), .a_readonly(), .a_capacity(),
    /* verilator lint_on PINCONNECTEMPTY */
    .a_req_read(hdd_a_req_read), .a_req_write(hdd_a_req_write), .a_req_lba(hdd_a_req_lba),
    .a_req_window(hdd_a_req_window), .a_req_unit(hdd_a_req_unit),
    .a_req_done(hdd_a_req_done), .a_req_error(hdd_a_req_error),
    /* verilator lint_off PINCONNECTEMPTY */   // the detector's `busy` replaces it
    .a_busy(),
    /* verilator lint_on PINCONNECTEMPTY */
    .a_buf_we(hdd_a_buf_we), .a_buf_addr(hdd_a_buf_addr), .a_buf_data(hdd_a_buf_data),
    .a_buf_rd_addr(ata_buf_rd_addr), .a_buf_rd_data(ata_buf_rd_data),
    .a_sd_lba(hdd_sd_lba), .a_sd_blk_cnt(hdd_sd_blk_cnt),
    .a_sd_rd(hdd_sd_rd), .a_sd_wr(hdd_sd_wr),
    .a_sd_ack(img_ack), .a_sd_buff_din(img_buff_dout),

    // ---- slot 3: the second hard disk (the A port's requests with a_req_unit = 1) ----
    .d_img_mounted(hdd1_mounted), .d_img_readonly(img_readonly), .d_img_size(hdd1_size),
    .d_sd_lba(hdd1_lba), .d_sd_blk_cnt(hdd1_blk_cnt), .d_sd_rd(hdd1_rd), .d_sd_wr(hdd1_wr),
    .d_sd_ack(hdd1_ack), .d_sd_buff_din(hdd1_buff_din),

    // ---- slots 1/2: the floppy drives (pc9821_fdd_media) ----
    // ONE DEVICE PORT FOR TWO DRIVES. The medium has one byte stream and one fetch in flight, so
    // both drives' block requests arrive on the B side and `b_req_slot` names the image (slot B
    // = FDD0, slot C = FDD1). The engine is loaded with that image at the hand-over, which
    // flushes its read-ahead window - see this module's header for why that flush is what keeps
    // one drive's cached blocks out of the other's reads.
    .b_img_mounted(fdd_mounted), .b_img_readonly(img_readonly), .b_img_size(fdd_size),
    .b_req_read(fdd_blk_rd), .b_req_write(fdd_blk_wr),
    .b_req_lba(fdd_blk_lba), .b_req_slot(fdd_blk_slot),
    .b_req_done(fdd_blk_done), .b_req_error(fdd_blk_error), .b_busy(fdd_blk_busy),
    .b_buf_we(fdd_blk_fill_we), .b_buf_addr(fdd_blk_fill_addr),
    .b_buf_data(fdd_blk_fill_data),
    .b_buf_rd_addr(fdd_blk_rd_addr), .b_buf_rd_data(fdd_blk_rd_data),
    .b_sd_lba(fdd_lba), .b_sd_blk_cnt(fdd_blk_cnt),
    .b_sd_rd(fdd_rd), .b_sd_wr(fdd_wr),
    .b_sd_ack(fdd_ack), .b_sd_buff_din(fdd_buff_din),

    .c_img_mounted(fdd1_mounted), .c_img_readonly(img_readonly), .c_img_size(fdd1_size),
    .c_sd_lba(fdd1_lba), .c_sd_blk_cnt(fdd1_blk_cnt),
    .c_sd_rd(fdd1_rd), .c_sd_wr(fdd1_wr),
    .c_sd_ack(fdd1_ack), .c_sd_buff_din(fdd1_buff_din),

    // ---- the one host channel both slots share (hps_io's shared sd_buff bus) ----
    .sd_buff_wr(disk_buff_wr), .sd_buff_addr(disk_buff_addr),
    .sd_buff_dout(disk_buff_dout),

    .dbg_hps_cycles(hdd_hps_cycles)
);
assign img_lba = hdd_sd_lba;
// The transfer width the adapter chose for its handshake (hps_io's blocks-1 field):
// multi-block for a run of sequential reads (the read-ahead window), single-block for
// writes and random reads, so a write can never stream more than its one-sector buffer.
assign img_blk_cnt = hdd_sd_blk_cnt;
assign img_rd = hdd_sd_rd;
// Write direction: the host reads the drive's sector buffer through
// img_buff_dout at whatever address it presents on img_buff_addr.
assign img_wr = hdd_sd_wr;

// ------------------------------------------------------------------ the floppy media
// pc9821_fdd_media owns the D88/raw images of BOTH drives and serves them to the FDC (inside
// pc9821_iobus) over the byte seam below, one request at a time with `unit` naming the drive.
// Its HPS fetches go through the SAME block adapter as the hard disk's (pc9821_block_share
// above): every slot reaches one hps_io channel, which serves one block transfer at a time, so
// the floppy asks over the block seam declared below instead of owning a second engine - and
// `fdd_blk_slot` tells the adapter which of its two images the fetch belongs to.
wire [1:0]  fdd_media_present;
// [u] the medium's write-protect state, from the media module (the D88 header's protect bit OR
// the mount's read-only flag): the FDC's ST3 WP bit and its write commands' NW refusal.
wire [1:0]  fdd_media_wp;
// [u] the media-change tag (one toggle per mount event), for the FDC's NP2kai ready-change
// interrupt (pc9821_fdc's media_chg).
wire [1:0]  fdd_media_chg;
wire        fdd_req, fdd_req_hdr, fdd_adv;
wire        fdd_req_wr;   // the FDC's request is a WRITE DATA sector
wire [7:0]  fdd_din;      // the byte a write stores at fdd_adv
wire        fdd_abort;    // the FDC abandoned the request in flight
wire [1:0]  fdd_unit;
wire [7:0]  fdd_c, fdd_h, fdd_r, fdd_n, fdd_idx;
wire [7:0]  fdd_tc;    // the physical track the sector is looked for on (pc9821_fdc's media_tc)
wire        fdd_hd;
wire        fdd_mf;    // the command's MF bit (pc9821_fdc's media_mf)
wire        fdd_2hd;   // the media mode the request is read in (pc9821_fdc's media_2hd)
wire        fdd_rpm;
wire        fdd_ready, fdd_rdy, fdd_hdrv, fdd_err;
wire [7:0]  fdd_dout, fdd_hr, fdd_hn, fdd_hs;

// The floppy's block seam to the shared adapter: the medium owns its images and its byte
// stream, the shared engine owns the HPS fetches (pc9821_block_share's B side).
wire        fdd_blk_rd, fdd_blk_busy, fdd_blk_done, fdd_blk_slot;
// The completion's verdict. pc9821_fdd_media consumes it (blk_err): a fetch the adapter failed -
// the slot was ejected or remounted under it - is not the medium's data, and the request that
// wanted it ends with `err` instead of reading the buffer's previous contents.
wire        fdd_blk_error;
wire [15:0] fdd_blk_lba;
wire        fdd_blk_fill_we;
wire [ 7:0] fdd_blk_fill_addr;
wire [15:0] fdd_blk_fill_data;
// The write-back: the request is a block WRITE, and the host reads the medium's buffer out.
wire        fdd_blk_wr;
wire [ 7:0] fdd_blk_rd_addr;
wire [15:0] fdd_blk_rd_data;

pc9821_fdd_media fdd_media (
    .clk(clk_sys), .reset(reset || !cpu_run),
    .img_mounted(fdd_mounted), .img_size(fdd_size),
    .img1_mounted(fdd1_mounted), .img1_size(fdd1_size),
    // The mount's read-only flag, the SAME one-bit register the block adapter takes (hps_io
    // holds one, valid at the mount) - the module latches it per drive at that drive's pulse.
    .img_readonly(img_readonly),
    .blk_req_rd(fdd_blk_rd), .blk_req_lba(fdd_blk_lba), .blk_slot(fdd_blk_slot),
    .blk_done(fdd_blk_done), .blk_err(fdd_blk_error), .blk_busy(fdd_blk_busy),
    .blk_fill_we(fdd_blk_fill_we), .blk_fill_addr(fdd_blk_fill_addr),
    .blk_fill_data(fdd_blk_fill_data),
    .blk_req_wr(fdd_blk_wr), .blk_rd_addr(fdd_blk_rd_addr), .blk_rd_data(fdd_blk_rd_data),
    .present(fdd_media_present), .writeprotect(fdd_media_wp), .chg(fdd_media_chg),
    .req(fdd_req), .req_hdr(fdd_req_hdr), .req_wr(fdd_req_wr), .unit(fdd_unit),
    .req_c(fdd_c), .req_h(fdd_h), .req_tc(fdd_tc), .req_hd(fdd_hd), .req_mf(fdd_mf), .req_2hd(fdd_2hd), .req_rpm(fdd_rpm), .req_r(fdd_r), .req_n(fdd_n), .req_idx(fdd_idx),
    .ready(fdd_ready), .rdy(fdd_rdy), .hdrv(fdd_hdrv), .err(fdd_err),
    .dout(fdd_dout), .adv(fdd_adv), .din(fdd_din), .abort(fdd_abort),
    .hdr_r(fdd_hr), .hdr_n(fdd_hn), .hdr_sects(fdd_hs)
);

// The uPD71071's bus-master port, from pc9821_iobus to the memory subsystem's arbiter.
wire [31:0] dma_mem_addr, dma_mem_din;
wire [31:0] dma_mem_addr_nx;   // the address dma_mem_addr loads next, and the cycle it loads (pc9821_dmac)
wire        dma_mem_load;
wire [3:0]  dma_mem_be;
wire        dma_mem_req, dma_mem_we, dma_mem_ready, dma_mem_resp_valid;
wire [31:0] dma_mem_dout;

// Both GDC domains are held in reset until the firmware pack has loaded (cpu_run);
// `rst_n_sys` names that strobe. `rst_n_vid` is the RASTER POSITION COUNTER's own reset
// and is DIFFERENT (see below): it is freed from `cpu_run` so the machine emits its
// power-on defsyncm24 raster with no firmware pack - the analog OSD is drawn in the core's
// own timing, so without a raster the analog picture and its OSD cannot exist and a ROM
// cannot be loaded from that OSD.
wire rst_n_sys = !(reset || !cpu_run);
// The raster position counter runs from `!reset` (rst_n_vid, below), so with no ROM it
// still emits the power-on defsyncm24 raster even though cpu_run never rises - the analog
// OSD is drawn in the core's own timing and cannot be placed without a raster.
//
// When a pack DOES load, cpu_run rises while the counter is mid-frame. The counter is
// RE-SEEDED to 0 on that one cycle (cpu_run_rise), so the raster phase the guest then sees
// is the phase it was held at before (rst_n_sys == !cpu_run until then). This is what keeps
// every guest-visible raster time - the boot's VSYNC-locked cycle count above all -
// unchanged; without it the free-running counter's phase at cpu_run would move them.
//
// Single-cycle-event discipline: the re-seed is a synchronous reset with exactly one
// consumer (the CRTC's hdot/vline always block); it collides with no other writer of those
// registers. The delayed cpu_run is its own register (the telemetry disk-mount latch's
// cpu_run_d is compiled out with PERF_LOG_EN), reset by `reset`, so the pulse is
// deterministic (no X in 4-state).
reg raster_cpu_run_d;
always @(posedge clk_sys) begin
  if (reset) raster_cpu_run_d <= 1'b0;
  else       raster_cpu_run_d <= cpu_run;
end
wire cpu_run_rise = cpu_run & ~raster_cpu_run_d;
wire rst_n_vid = !(reset || cpu_run_rise);

// The EGC x GRCG memory-dispatch gate: `gdc_egc_gate` (pc9821_crtc's
// FF2 num-2 latch) is ANDed with `mem_grcg_expand` (pc9821_grcg's 0x7C bit 7) and the AND is
// REGISTERED FROM BOTH SOURCES' NEXT STATE. That is a true pipeline relocate - the register is
// bit-identical to the combinational gate in every cycle - and it is placed here, near the
// memory subsystem, so the crtc-launched GVRAM-M10K cone is cut (docs/timing.md).
pc9821_egc_mem_gate u_egc_mem_gate (
    .clk(clk_sys), .reset(!rst_n_sys),
    .egc_gate(gdc_egc_gate), .egc_gate_nx(gdc_egc_gate_nx),
    .grcg_expand(mem_grcg_expand), .grcg_expand_nx(mem_grcg_expand_nx),
    .gate(gdc_egc_mem_gate)
);

// pc9821_crtc's video-domain outputs, declared before the instance that brings them
// out: the text-plane opaque/cell/colour triple the mixer below combines.
wire        gdc_text_opaque, gdc_text_cell;
wire [11:0] gdc_text_colour;
wire [9:0]  gdc_pix_dot;
wire        gdc_pix_h_active, gdc_pix_v_active;
// The 200-line interleave's odd display line (MODE FF1 bit 4): the compositor hides the
// graphics plane on it and the line fetch skips it (NP2kai vram/makegrph.c:155,
// vram/sdraw.mcr:199-243 p_2i - see pc9821_crtc's v_mode1_200).
wire        gdc_gfx_odd_line;
wire        gdc_mode16;
wire [31:0] gdc_dig;
// The analogue palette table's CPU write port, from pc9821_gdc_text to pc9821_gfx_palette
// inside the mixer (#2).
wire        gdc_pal_wr_en;
wire [3:0]  gdc_pal_wr_idx;
wire [1:0]  gdc_pal_wr_chan;
wire [3:0]  gdc_pal_wr_data;
wire        gdc_pal256_wr_en;
wire [7:0]  gdc_pal256_wr_idx, gdc_pal256_wr_data;
wire [1:0]  gdc_pal256_wr_chan;
/* verilator lint_off UNUSEDSIGNAL */   // PERF_LOG_EN=0: the GDC taps here lose their only reader
// The GDC's own SAD/pitch/40-column/display diagnostic latches, formatted by the watchdog.
wire [15:0] gdc_dbg_sad;
wire  [7:0] gdc_dbg_pitch;
wire        gdc_dbg_col40, gdc_dbg_disp;
wire [15:0] gdc_dbg_wk_skips;   // the JIS row-cache walker's skipped-walk counter
// The raster's frame boundary the machine raises its vblank interrupt on: one clk_sys pulse at
// the VSYNC pulse's rising edge (vline 407, VACTIVE + VFP), which is where MAME's uPD7220 device
// puts the VSYNC output's rise and therefore the PC-98's IRQ2 (pins the phase). It is the
// perf record's pass-duration reference, so the pass is measured from the edge the guest wakes on.
// It is also the FDC's frame for NP2kai's per-frame floppy insert delay (pc9821_fdc's frame_tick).
wire        gdc_vsync_edge;
/* verilator lint_on UNUSEDSIGNAL */

// The text video path is three modules: pc9821_crtc (raster, text
// fetch/render, pixel outputs), pc9821_gdc2 (the graphics display address) and
// pc9821_cg (the glyph fetch, row cache, window and configuration record). The CPU's
// CG-window and font-request ports come straight from pc9821_cg to
// pc9821_memory_subsystem, not through a video module. All three run on clk_sys gated
// by pixel_ce - there is no second video clock.
//
// The configuration image the ITF reads out of the battery-backed CG store is seeded here
// from the size the OSD actually selected, and RE-ESTABLISHED at every ITF POST pass.
// cpu_reset_req is the `out 0xF0` CPU-mode reset (pc9821_iobus:1337), the same event the
// ITF uses to retry POST, and it is what clears the seeded cells' written mask so the
// KANJI test's own writes and the ITF's configuration reads both work.
// Both consumers are fed from pc9821_system's own code-to-bytes table, which is the one
// place the OSD list's positions are turned into a size.
wire [10:0] crtc_ank_rd_addr;
wire [15:0] cg_ank_word;
wire [1:0]  crtc_jc_rd_bank;
wire [6:0]  crtc_jc_rd_cell;
wire [1:0]  crtc_jc_rd_word;
wire [31:0] cg_jc_rd_q;
wire [12:0] crtc_cg_ram_vid_addr;
wire [7:0]  cg_cg_ram_vid_q;
wire        cg_wk_tr_read;
wire [13:0] cg_wk_tr_addr;
wire [7:0]  crtc_tram_vid_q;
wire [7:0]  crtc_o_v_pitch;
wire        crtc_o_v_col40;
wire [15:0] crtc_o_v_sad;
wire        crtc_o_wk_go;
wire [9:0]  crtc_o_wk_k;
wire [1:0]  crtc_o_wk_bank;
wire [9:0]  crtc_o_vline;
wire [9:0]  crtc_o_vtotal;
wire [5:0]  crtc_o_vbp;
wire [9:0]  crtc_o_hdot;
wire        crtc_o_frame_end, crtc_o_cfg_snap, crtc_o_cfg_pending, crtc_o_display_page;
wire        crtc_o_stat_blank, crtc_o_stat_vsync;
wire [7:0]  crtc_io_dout, cg_io_dout, gdc2_io_dout;

pc9821_crtc u_crtc (
    .clk_sys(clk_sys), .rst_n_sys(rst_n_sys), .rst_n_vid(rst_n_vid), .pixel_ce(pixel_ce),
    // The slave's graphics window extends the displayed lines (NP2kai's MAX(grphymax, textymax)).
    .gfx_win_on(gdc_gfx_grph_on),
    .crt31k(crt31k),
    .io_wr(device_io_wr && gdc_cs), .io_rd(device_io_rd && gdc_cs),
    .io_addr(device_io_addr[7:0]),
    .io_din(device_io_din), .io_dout(crtc_io_dout),
    // The ONE HARDWARE-switch field the OSD owns; pc9821_crtc latches it on rst_n_sys and
    // seeds the 0xA3FF2 cell with it (0xA3FEA's base memory is hardcoded to 640 KB).
    .cfg_fdd_mode(cfg_fdd_mode),
    .tram_cpu_addr(tram_addr), .tram_cpu_din(tram_din),
    .tram_cpu_we(tram_we), .tram_cpu_dout(tram_dout),
    .wk_tr_read(cg_wk_tr_read), .wk_tr_addr(cg_wk_tr_addr),
    .o_tram_vid_q(crtc_tram_vid_q),
    .ank_rd_addr(crtc_ank_rd_addr), .ank_word(cg_ank_word),
    .jc_rd_bank(crtc_jc_rd_bank), .jc_rd_cell(crtc_jc_rd_cell),
    .jc_rd_word(crtc_jc_rd_word), .jc_rd_q(cg_jc_rd_q),
    .cg_ram_vid_addr(crtc_cg_ram_vid_addr), .cg_ram_vid_q(cg_cg_ram_vid_q),
    .o_v_pitch(crtc_o_v_pitch), .o_v_col40(crtc_o_v_col40),
    // o_v_row0_stale is the row-0 re-walk flag pc9821_crtc folds into its own walk request
    // (o_wk_go); the benches read it, the core does not.
    /* verilator lint_off PINCONNECTEMPTY */
    .o_v_sad(crtc_o_v_sad), .o_v_row0_stale(), .o_wk_go(crtc_o_wk_go),
    /* verilator lint_on PINCONNECTEMPTY */
    .o_wk_k(crtc_o_wk_k), .o_wk_bank(crtc_o_wk_bank),
    .o_vline(crtc_o_vline), .o_hdot(crtc_o_hdot),
    .o_htotal(crtc_o_htotal), .o_vtotal(crtc_o_vtotal), .o_vbp(crtc_o_vbp),
    .o_frame_end(crtc_o_frame_end), .o_cfg_snap(crtc_o_cfg_snap),
    .o_cfg_pending(crtc_o_cfg_pending),
    .o_display_page(crtc_o_display_page), .o_stat_blank(crtc_o_stat_blank),
    .o_stat_vsync(crtc_o_stat_vsync),
    /* verilator lint_off PINCONNECTEMPTY */   // the level is unused: this core reads vsync_irq
    .vsync_active(), .vsync_edge(gdc_vsync_edge),
    /* verilator lint_on PINCONNECTEMPTY */
    .vsync_irq_arm(gdc_vsync_arm), .vsync_irq(gdc_vsync_irq),
    .disp_on(gdc_disp), .gfx_access_page(gdc_access_page),
    .gfx_egc_gate(gdc_egc_gate),
    .gfx_egc_gate_nx(gdc_egc_gate_nx),
    .gdc_ff2_state(gdc_ff2_state),
    .dbg_sad(gdc_dbg_sad), .dbg_pitch(gdc_dbg_pitch),
    .dbg_col40(gdc_dbg_col40), .dbg_disp(gdc_dbg_disp),
    .text_opaque(gdc_text_opaque), .text_cell(gdc_text_cell),
    .text_colour(gdc_text_colour),
    .pix_dot(gdc_pix_dot), .pix_h_active(gdc_pix_h_active),
    .pix_v_active(gdc_pix_v_active),
    .gfx_odd_line(gdc_gfx_odd_line),
    .gfx_mode16(gdc_mode16), .gfx_dig(gdc_dig),
    .pal_wr_en(gdc_pal_wr_en), .pal_wr_idx(gdc_pal_wr_idx),
    .pal_wr_chan(gdc_pal_wr_chan), .pal_wr_data(gdc_pal_wr_data),
    .pal256_wr_en(gdc_pal256_wr_en), .pal256_wr_idx(gdc_pal256_wr_idx),
    .pal256_wr_chan(gdc_pal256_wr_chan), .pal256_wr_data(gdc_pal256_wr_data),
    .gfx_pegc_256(gdc_pegc_256), .gfx_pegc_256e(gdc_pegc_256e),
    .hs_out(video_hsync), .vs_out(video_vsync), .de_out(gdc_de)
);

pc9821_gdc2 #(
    .SYS_FREQ(SYS_FREQ),
    .WRITE_PACE_NS(GDC_WRITE_PACE_NS),
    .FIG_PACE_NS(GDC_FIG_PACE_NS)
) u_gdc2 (
    .clk_sys(clk_sys), .rst_n_sys(rst_n_sys), .pixel_ce(pixel_ce),
    .io_wr(device_io_wr && gdc_cs), .io_rd(device_io_rd && gdc_cs),
    .io_addr(device_io_addr[7:0]),
    .io_din(device_io_din), .io_dout(gdc2_io_dout),
    .frame_end(crtc_o_frame_end), .cfg_snap(crtc_o_cfg_snap),
    .cfg_pending(crtc_o_cfg_pending),
    .vline(crtc_o_vline), .vtotal(crtc_o_vtotal), .m_vbp(crtc_o_vbp),
    .display_page(crtc_o_display_page),
    .stat_blank(crtc_o_stat_blank), .stat_vsync(crtc_o_stat_vsync),
    // The draw path's route gates and its GVRAM visits (the GDC2 WRITE slice): the route is
    // latched per draw from these two gates exactly as NP2kai's gdcpset_prepare picks
    // its pset functions once (io/gdc_pset.c:117-137).
    .egc_mem_gate(gdc_egc_mem_gate), .grcg_cg_gate(mem_grcg_expand),
    .access_page(gdc_access_page),
    .mem_valid(gdc_mem_valid), .mem_ready(gdc_mem_ready),
    .mem_write(gdc_mem_write),
    .mem_route_egc(gdc_mem_route_egc),
    .mem_route_grcg(gdc_mem_route_grcg),
    .mem_page(gdc_mem_page), .mem_plane(gdc_mem_plane),
    .mem_offset(gdc_mem_offset), .mem_din(gdc_mem_din),
    .mem_be(gdc_mem_be),
    .mem_resp(gdc_mem_resp), .mem_rdata(gdc_mem_rdata),
    .gfx_line_addr(gdc_gfx_line_addr), .gfx_walk_page(gdc_gfx_walk_page),
    /* verilator lint_off PINCONNECTEMPTY */   // gfx_disp/gfx_win_off are gfx_grph_on's two terms, read by the benches only
    .gfx_disp(), .gfx_win_off(),
    /* verilator lint_on PINCONNECTEMPTY */
    .gfx_grph_on(gdc_gfx_grph_on), .pegc_256(gdc_pegc_256),
    // The 5 MHz GDC clock: both FF2 clock bits (pc9821_crtc's gdc_ff2_state [7] and [8],
    // 0x6A dat 0x83 and 0x85) - the packed walk's PITCH select (NP2kai vram/makegrex.c:288).
    .gdc_5m(gdc_ff2_state[7] && gdc_ff2_state[8])
);

pc9821_cg u_cg (
    .clk_sys(clk_sys), .rst_n_sys(rst_n_sys), .pixel_ce(pixel_ce),
    .io_wr(device_io_wr && gdc_cs), .io_rd(device_io_rd && gdc_cs),
    .io_addr(device_io_addr[7:0]), .io_din(device_io_din), .io_dout(cg_io_dout),
    .cg_win_byte_sel(cg_win_byte_sel), .cg_win_rd(cg_win_rd),
    .cg_win_dout(cg_win_dout), .cg_win_din(cg_win_din), .cg_win_we(cg_win_we),
    .cg_win_byte_hold(cg_win_byte_hold),
    .font_req_addr(font_req_addr), .font_req(font_req),
    .font_word_valid(font_word_valid), .font_word_data(font_word_data),
    .cg_rd_hold(cg_rd_hold),
    .font_ld_addr(font_addr), .font_ld_data(font_data), .font_ld_we(font_we),
    .cg_record_restore(sdip_seed_pulse),
    .setup_cfg(setup_cfg),
    // The Machine field reaches the record's model table; cfg_seed_en gates the static
    // configuration view. Both are sampled into reset-time latches inside pc9821_cg.
    .bios_set(bios_set),
    .cfg_ram_mib(cfg_ram_mib), .cfg_seed_en(1'b1),
    .cfg_seed_reload(cpu_reset_req),
    .ank_rd_addr(crtc_ank_rd_addr), .ank_word(cg_ank_word),
    .jc_rd_bank(crtc_jc_rd_bank), .jc_rd_cell(crtc_jc_rd_cell),
    .jc_rd_word(crtc_jc_rd_word), .jc_rd_q(cg_jc_rd_q),
    .cg_ram_vid_addr(crtc_cg_ram_vid_addr), .cg_ram_vid_q(cg_cg_ram_vid_q),
    .tram_vid_q(crtc_tram_vid_q),
    .v_pitch(crtc_o_v_pitch), .v_col40(crtc_o_v_col40),
    .v_sad(crtc_o_v_sad),
    .wk_go(crtc_o_wk_go), .wk_k(crtc_o_wk_k), .wk_bank_in(crtc_o_wk_bank),
    .hdot(crtc_o_hdot),
    .wk_tr_read(cg_wk_tr_read), .wk_tr_addr(cg_wk_tr_addr),
    .dbg_wk_skips(gdc_dbg_wk_skips)
);

// The device bus answers from the one module whose ports the address names.
assign gdc_io_dout =
    ((device_io_addr[7:0] == 8'hA0) || (device_io_addr[7:0] == 8'hA2)) ? gdc2_io_dout :
    ((device_io_addr[7:0] == 8'hA1) || (device_io_addr[7:0] == 8'hA3) ||
     (device_io_addr[7:0] == 8'hA5) || (device_io_addr[7:0] == 8'hA9)) ? cg_io_dout :
    crtc_io_dout;

// The graphics plane's line-buffer read port is pc9821_gvram's, and pc9821_gvram
// lives inside pc9821_memory_subsystem (the wires are at the scanout
// block above). The mixer below is that port's reader and the only one: it owns
// the read sequencer, so the graphics side of the picture is the fetched line as
// soon as graphics display is enabled (R7), with no second route to the planes.

// The compositor rule: 2'b00 is NP2kai's p_2 rule (a glyph-covered dot opaque
// in the attribute colour, everything else showing graphics). It is a select
// and not a hard wire because that rule is a model, not a measurement.
localparam [1:0] COMP_RULE = 2'b00;
// The graphics display enable is the slave GDC's START/STOP latch AND its SYNC window.
// pc9821_gdc2 decodes the 0xA2 command that sets it and exports it as gdc_gfx_grph_on, so
// the compositor follows the guest. Reset leaves it off, so a guest that never issues
// START paints black where a graphics pixel would be.

pc9821_video_mixer video_mixer (
    .clk(clk_sys),
    .dot_x(gdc_pix_dot),
    .h_active(gdc_pix_h_active), .v_active(gdc_pix_v_active),
    .gfx_odd_line(gdc_gfx_odd_line),
    .text_opaque(gdc_text_opaque), .text_cell(gdc_text_cell),
    .text_colour(gdc_text_colour),
    .line_data(gvram_line_data),
    .line_ready(gdc_pegc_256 ? peg_line_ready : gvram_line_ready),
    .line_sel(gdc_pegc_256 ? peg_line_sel : gvram_line_sel),
    .line_rd_addr(gvram_line_rd_addr), .line_rd_sel(gvram_line_rd_sel),
    .pal_mode16(gdc_mode16), .pal_dig(gdc_dig),
    .pal_wr_en(gdc_pal_wr_en), .pal_wr_idx(gdc_pal_wr_idx),
    .pal_wr_chan(gdc_pal_wr_chan), .pal_wr_data(gdc_pal_wr_data),
    // The PEGC arm: the 256-colour write port (the crtc's widened palette
    // decode), the mode mux, and the fold seam. packed_idx is pc9821_pegc_scan's
    // packed dot; fold_bypass/pegc_256 are the same view select the map's window
    // arms take.
    .pegc_256(gdc_pegc_256),
    .fold_bypass(gdc_pegc_256), .packed_idx(peg_packed_idx),
    .pal256_wr_en(gdc_pal256_wr_en), .pal256_wr_idx(gdc_pal256_wr_idx),
    .pal256_wr_chan(gdc_pal256_wr_chan), .pal256_wr_data(gdc_pal256_wr_data),
    // Outside the slave SYNC's graphics window the graphics plane is black in BOTH modes
    // (NP2kai dispsync_renewalvertical and makegrex.c makegrphex; pc9821_gdc2's gfx_grph_on).
    .comp_rule(COMP_RULE), .grph_disp(gdc_gfx_grph_on),
    .r_out(video_r), .g_out(video_g), .b_out(video_b)
);
// The mixer is pc9821_gvram's scanout read-port reader; pc9821_gvram owns the line fetch,
// the ping-pong line buffer and the pacing behind it.
//
// Pixel enable at the PC-98 dot rate, exactly 400/19 MHz (21.0526 MHz) at every SYS_FREQ, or the
// 31 kHz mode's 25.168 MHz while 0x09A8 bit 0 is set (pc9821_vclk_pkg): the raster
// and everything guest-visible stay on clk_sys, gated by it. The OUTPUT leaves on its own dot-locked
// video clock (z486_mister.sv: pc9821_video_out, the video PLL), which is what CLK_VIDEO must be for
// a jitter-free analog picture; the two dot rates are the same exact ratio of the 50 MHz reference.
pc9821_dot_ce #(.SYS_FREQ(SYS_FREQ)) dot_ce (
    .clk(clk_sys), .reset(reset), .c31(crt31k), .ce(pixel_ce)
);
assign video_ce = pixel_ce;   // the framework's CE_PIXEL (see pixel_ce above)
assign video_31k = crt31k;
assign video_blank_n = gdc_de;

// The keyboard's PS/2 response pins are idle (the guest is driven through ps2_key).
assign ps2_kbclk_out = 1'b1;
assign ps2_kbdat_out = 1'b1;
// THE PERFORMANCE LOG IS COMPILED OUT, NOT DISABLED, unless PERF_LOG_EN is set: with 0 the
// section below does not exist at all, and dbg_uart_byte/dbg_uart_we are tied off, which makes the
// top level's `core_dbg_uart_we && ...` enqueue arm dead. That is the same treatment TRACE_EN gives
// the instruction trace at z486_mister.sv, and it is a build-time constant rather than a runtime
// switch because the shipped bitstream must not carry the telemetry's logic or its ~621-byte
// report machinery.
generate
if (PERF_LOG_EN) begin : g_telemetry
assign cd_log_accept = dbg_uart_accept;   // the CD log is compiled out with the telemetry on
// Telemetry: the stall record, 351 characters on ONE line (~31 ms at 115200 8N1) so it must not
// restart mid-record, followed by the 232-byte PRF record and then the 100-byte GFX record. The
// field map is NOT repeated here - it is a contract with tools/decode_telemetry.py and
// tools/check_telemetry_contract.py. The three formatters below produce the bytes and
// pc9821_dbg_record sequences them; those say what the bytes mean. The formatters are pure
// functions of their byte index over the report's counter SNAPSHOT (their `snap` input, the
// trigger's `start`), so the digits of one record are one instant however long the paced
// emission waits.

// DO NOT READ THE CADENCE INSTEAD: z_valid is a LEVEL (src/z486/memory.sv:173 `output valid`), so arrival and
// completion give the same 2 s spacing, which is why the byte exists.
localparam [31:0] WDG_STALL = 32'(SYS_FREQ) / 32'd5;
// The stall trigger alone cannot see a *loop*: a guest that spins while still
// issuing memory requests resets the completion counter forever, and that is exactly the
// state a spinning guest gets stuck in. The same message is therefore also emitted every
// WDG_PERIOD whether or not the CPU is busy, which costs about 1% of the line at
// 115200 (the whole report is ~59 ms of characters, about 3 % of a 2 s line).
localparam [31:0] WDG_PERIOD = 32'(SYS_FREQ) * 32'd2;
wire [7:0]  wdg_char;
wire [7:0]  prf_char;
wire [7:0]  gfx_char;
wire [7:0]  wdg_path;     // 'W' wedged / 'S' idle / 'P' heartbeat, latched at the trigger
wire        wdg_start;    // begin a record
// The byte each formatter is being asked for, owned by pc9821_dbg_record: they are its counters.
wire  [8:0] wdg_idx;
wire  [8:0] prf_idx;
wire  [6:0] gfx_idx;
wire        dbg_report_active;   // one report (all three records) is in flight; drives `hold`
pc9821_wdg_trigger #(
    .WDG_STALL (WDG_STALL),
    .WDG_PERIOD(WDG_PERIOD)
) u_wdg_trigger (
    .clk(clk_sys), .reset(reset), .cpu_run(cpu_run),
    // The hold covers the PRF and GFX records too: the halves of one report must not be separated
    // by a new trigger, or a counter delta would straddle two reports. dbg_report_active is a
    // level over all three of them, and it also holds the trigger while the emission is PACED on
    // the debug FIFO's handshake, so the counters in the record stay one interval's
    // however long the FIFO takes to accept the bytes.
    .hold(dbg_report_active), .z_valid(z_valid), .z_ready(z_ready),
    .path(wdg_path), .start(wdg_start)
);
// The disk-activity, mount and video counters the watchdog record formats. Declared before
// the wdg_msg instance below, their first reader.
// Disk transfer activity, reported by the watchdog: whether the guest asks
// for sectors at all, and whether the ATA aborted them. B is the block
// engine's busy flag, which separates "still waiting for the host transfer"
// from "finished with an error" (hierarchical references into the ATA are not
// synthesisable, so only module-level signals are used here).
reg [7:0] hdd_req_cnt, hdd_err_cnt;
// Whether the host had already mounted an image when the CPU was released. The
// benches always mount before releasing the CPU (matching the MGL delays), but
// on hardware that ordering belongs to the host, and the guest probes the disk
// once during startup and does not retry a drive that appeared later.
reg mounted_at_run;
// The video-domain diagnostics, synchronised into clk_sys below.
reg [7:0] vid_frame_cnt, vid_lit_cnt;
reg       vid_lit_seen;

// The record itself, and the 137 bytes in it that carry diagnostic fields, live
// in their own module: it is a pure function of wdg_idx over the fields'
// report-accept snapshot (its `snap`, shared with the two formatters below),
// its 214 literal bytes are a ROM there rather than mux logic here, and
// tb_pc9821_watchdog.sv holds the record to a golden capture of the formatter
// this instantiation replaced.
pc9821_watchdog_msg u_wdg_msg (
        .clk(clk_sys), .snap(wdg_start),
        .idx(wdg_idx), .cpu_cs(cpu_cs), .cpu_eip(cpu_eip), .io_debug_status(io_debug_status),
        .triple_fault_reset(triple_fault_reset), .hdd_mounted(hdd_mounted),
        .hdd_capacity(hdd_capacity), .gdc_disp(gdc_disp), .vid_frame_cnt(vid_frame_cnt),
        .hdd_req_cnt(hdd_req_cnt), .hdd_err_cnt(hdd_err_cnt), .hdd_busy(hdd_busy),
        .hdd_hps_cycles(hdd_hps_cycles),
        .vid_lit_seen(vid_lit_seen), .vid_lit_cnt(vid_lit_cnt), .ata_dbg_state(ata_dbg_state),
        .ata_dbg_cmd(ata_dbg_cmd), .io_dbg_gate(io_dbg_gate), .mounted_at_run(mounted_at_run),
        .gdc_dbg_sad(gdc_dbg_sad), .gdc_dbg_pitch(gdc_dbg_pitch), .gdc_dbg_col40(gdc_dbg_col40),
        .gdc_dbg_disp(gdc_dbg_disp), .kbd_dbg_events(kbd_dbg_events),
        .kbd_dbg_delivered(kbd_dbg_delivered), .kbd_dbg_rd_data(kbd_dbg_rd_data),
        .kbd_dbg_wr_ctrl(kbd_dbg_wr_ctrl), .kbd_dbg_rts(kbd_dbg_rts),
        .kbd_dbg_rx_en(kbd_dbg_rx_en), .kbd_irq(kbd_irq), .kbd_dbg_last_del(kbd_dbg_last_del),
        .kbd_dbg_ctrl0(kbd_dbg_ctrl0), .kbd_dbg_ctrl1(kbd_dbg_ctrl1), .irq_dbg_imr(irq_dbg_imr),
        /* verilator lint_off WIDTHTRUNC */   // bits 31:8 of cpu_inta_din are always zero
        .irq_dbg_irr(irq_dbg_irr), .irq_dbg_isr(irq_dbg_isr), .inta_din(inta_din),
        /* verilator lint_on WIDTHTRUNC */
        // WIDTHTRUNC above is exact, not lossy: pc9821_inta_bridge declares cpu_inta_din as
        // 32 bits but assigns it only 32'h0 or {24'h0, vector}, so bits 31:8 are always zero.
        // Narrowing it is a three-file change (that port, pc9821_interrupts.sv, this wire) and
        // belongs to the module that declares the width, not to this instantiation.
        // CPU: {IF, 5'b0, INTR, 1'b0} - EFLAGS.IF and the CPU's interrupt request input.
        .cpu_irq_state({cpu_dbg_eflags[9], 5'd0, z_intr, 1'b0}), .inta_count(inta_count),
        .artic_hi(artic_hi), .io_itf_stage(io_itf_stage),
        .last_io_addr(dbg_last_io_addr), .last_io_data(dbg_last_io_data),
        .last_io_rd(dbg_last_io_rd), .last_io_wr(dbg_last_io_wr),
        .ata_dbg_lba(ata_dbg_lba), .ata_dbg_sec(ata_dbg_sec),
        .fdc_dbg_state(dbg_fdc_state), .fdc_dbg_cmd(dbg_fdc_cmd),
        .fdc_dbg_result(dbg_fdc_result), .fdc_dbg_chrn(dbg_fdc_chrn),
        .ch(wdg_char)
);

// Disk transfer activity continues at the ATA below; the counters are declared above the
// watchdog instance that reads them.

reg cpu_run_d;
always @(posedge clk_sys) begin
    if (reset) begin
        mounted_at_run <= 1'b0;
        cpu_run_d     <= 1'b0;
    end else begin
        cpu_run_d <= cpu_run;
        if (cpu_run && !cpu_run_d) mounted_at_run <= hdd_mounted;
    end
end
always @(posedge clk_sys) begin
    if (reset) begin
        hdd_req_cnt  <= 8'd0;
        hdd_err_cnt  <= 8'd0;
    end else begin
        if (ata_block_read) hdd_req_cnt <= hdd_req_cnt + 8'd1;
        if (ata_block_error) hdd_err_cnt <= hdd_err_cnt + 8'd1;
    end
end

// Video frame and lit-pixel counters. The GDC and its pixel outputs are in the
// clk_sys domain, gated by pixel_ce, so these count one dot per enable in the
// same domain.
reg [7:0] vid_frame_cnt_v;
reg       vid_vs_d_v;
reg [7:0] vid_lit_cnt_v;
reg       vid_lit_seen_v;
always @(posedge clk_sys) begin
    if (!rst_n_sys) begin
        vid_frame_cnt_v <= 8'd0;
        vid_vs_d_v      <= 1'b0;
        vid_lit_cnt_v   <= 8'd0;
        vid_lit_seen_v  <= 1'b0;
    end else if (pixel_ce) begin
        vid_vs_d_v <= video_vsync;
        if (video_vsync && !vid_vs_d_v) vid_frame_cnt_v <= vid_frame_cnt_v + 8'd1;
        // One pixel per enable, so the count advances on pixel_ce.
        if (video_r != 8'h00 || video_g != 8'h00 || video_b != 8'h00) begin
            vid_lit_cnt_v  <= vid_lit_cnt_v + 8'd1;
            vid_lit_seen_v <= 1'b1;
        end
    end
end

// The watchdog prints these from clk_sys, so each bit passes through a two-flop
// synchroniser. Reachability matters more than exactness for a free-running
// diagnostic: a read that catches a carry in flight may show an adjacent
// value, but per-bit synchronisation guarantees no metastable state propagates
// into clk_sys, which is the property that actually matters.
reg [7:0] vid_frame_cnt_s1, vid_lit_cnt_s1;
reg       vid_lit_seen_s1;
// Pipe stages are reset so the watchdog never formats X.
always @(posedge clk_sys) begin
    if (reset) begin
        vid_frame_cnt_s1 <= 8'd0;
        vid_frame_cnt    <= 8'd0;
        vid_lit_cnt_s1   <= 8'd0;
        vid_lit_cnt      <= 8'd0;
        vid_lit_seen_s1  <= 1'b0;
        vid_lit_seen     <= 1'b0;
    end else begin
        vid_frame_cnt_s1 <= vid_frame_cnt_v;
        vid_frame_cnt    <= vid_frame_cnt_s1;
        vid_lit_cnt_s1   <= vid_lit_cnt_v;
        vid_lit_cnt      <= vid_lit_cnt_s1;
        vid_lit_seen_s1  <= vid_lit_seen_v;
        vid_lit_seen     <= vid_lit_seen_s1;
    end
end
// The PRF record's counters. It watches the two handshakes that say where the time
// goes when nothing is wedged: the CPU's memory request (z_valid/z_ready, the same pair
// pc9821_wdg_trigger reads, so "waiting" has one definition in this tree) and the MAIN SDRAM
// port (ext_mem0_*, the mapper's CPU RAM and the firmware loader). That port does NOT carry the
// GVRAM, which is on-chip M10K and emits no SDRAM traffic at all; the scanout's line
// fetch and the font fetch have their own SDRAM ports besides. The graphics record
// reports the GVRAM path counters, and this record reports the EGC/GRCG operation counts too.
pc9821_perf_msg u_perf_msg (
    .clk(clk_sys), .reset(reset),
    .cpu_req(z_valid), .cpu_ack(z_ready),
    .sd_valid(ext_mem0_valid), .sd_ready(ext_mem0_ready), .sd_write(ext_mem0_write),
    // The other three SDRAM requester ports' accepts and the scanout's waiting cycles, so the
    // record can say WHICH client is loading the bus and whether the hard-deadline scanout is
    // being held off it. All four are clk_sys accepts from the bridge.
    .sd1_valid(ext_mem1_valid), .sd1_ready(ext_mem1_ready),
    .sd2_valid(ext_mem2_valid), .sd2_ready(ext_mem2_ready),
    .sd3_valid(ext_mem3_valid), .sd3_ready(ext_mem3_ready),
    .dbg_walk_start(gvram_walk_start), .dbg_walk_cycle(gvram_walk_cycle),
    .dbg_egc_txn(gvram_egc_txn), .dbg_egc_unit(gvram_egc_unit),
    .dbg_grcg_store(gvram_grcg_store),
    // The visible-region half: the raw ownership pulses are gated HERE, by the video
    // domain's v_active, so GV/EV count only the graphics cycles that landed on visible
    // scanlines, and the frame edge is the same edge the vblank IRQ rises on.
    .dbg_gr_owned(gvram_gr_owned), .dbg_eg_owned(gvram_eg_owned),
    // The third write owner: the plain plane-window store. Farland Story's page copies are
    // plain stores, so without this arm the probe below reads 0 through the very leak it wants.
    .dbg_pw_owned(gvram_pw_owned),
    .v_active(gdc_pix_v_active), .vsync_edge(gdc_vsync_edge),
    // The page-coincidence probe: the two raw page levels, paired with the three ownership
    // arms above, become the record's PC counter and its SP/AP status fields.
    .dbg_access_page(gvram_access_page), .dbg_scan_page_q(gvram_scan_page_q),
    // The CPU's LAST page fault: the faulting linear address and error code the core latches.
    // A page fault is normal here (DOS/4GW demand-pages), so PA/PF name the last one - the
    // fatal one when a capture is taken right after the guest stops.
    .dbg_pf_code(cpu_dbg_pf_code), .dbg_pf_addr(cpu_dbg_pf_addr),
    // The record's counters are a SNAPSHOT taken at the report's accept (wdg_start), so the
    // eight digits of every field are one instant however long the paced emission waits.
    .snap(wdg_start),
    .idx(prf_idx), .ch(prf_char)
);
// The GFX record's counters: the GVRAM's four partitioned path counters, the CPU's
// DEVICE wait (the I/O subset of pc9821_perf_msg's MW), and the frame and interrupt counts that
// turn the four cycle counts into a per-frame or per-interrupt cost.
wire gfx_vsync_pulse = pixel_ce && video_vsync && !vid_vs_d_v;   // the edge vid_frame_cnt_v counts
wire gfx_irq_pulse   = z_inta && !z_inta_d;                      // the edge inta_count counts
pc9821_gfx_msg u_gfx_msg (
    .clk(clk_sys), .reset(reset),
    .gvram_gr(gfx_stats[127:96]), .gvram_gt(gfx_stats[95:64]),
    .gvram_eg(gfx_stats[63:32]),  .gvram_pw(gfx_stats[31:0]),
    .cpu_req(z_valid), .cpu_ack(z_ready), .cpu_io(z_io),
    .vsync(gfx_vsync_pulse), .irq(gfx_irq_pulse),
    .wk_skips(gdc_dbg_wk_skips),
    // The same report-accept snapshot as pc9821_perf_msg: one instant for all three records.
    .snap(wdg_start),
    .idx(gfx_idx), .ch(gfx_char)
);

// THE TRACE'S SECOND TRIGGER: the end of a GRCG drawing burst - the event a game's dialog redraws
// ARE, and the one the OOM trigger cannot see. WHY THE BURST'S END AND NOT ITS START: the trace ring
// holds the PAST (8192 transitions), so a trigger at the burst's START dumps the idle loop the guest
// was waiting in, while a trigger at its END dumps the drawing that just happened, which is the
// whole point of having it.
// WHY A ONE-SECOND QUIET: a game draws a dialog and then sits in a keyboard wait with the GVRAM
// idle - measured on the running core, a dialog screen is quiet and an advance bursts to
// 145k-254k stores - so "a GVRAM store after >= 1 s with none" is exactly "an interaction just
// redrew the screen". That is rare enough that the trace's ~16 s dump is not swamped, and it is what
// makes pc9821_trace's per-pulse re-arm safe: one interaction, one dump.
// WHICH STORES COUNT: the WRITE owners only - the GRCG's store pulse and the plain client's
// ownership level. The plain arm is there because the GRCG's alone does not see Farland
// Story's drawing: its heartbeats move GW/GC/PW while GS/GR/GT stay flat, so its page-to-page
// copies are plain window stores and a GRCG-only trigger never fires on them (its copy loop
// is at 1459:05C7). READS are deliberately excluded - a client that polls a GVRAM byte every frame
// would reset the quiet timer forever and the trigger would never fire. THE EGC IS ALSO
// EXCLUDED, not overlooked: an EGC-driven game (Flame Zapper) may never go quiet, so it needs
// its own trigger shape rather than being folded in here untested.
// THE QUIET WINDOW IS ONE SECOND OF REAL TIME ON HARDWARE, which is what makes it free here - it is
// not a simulation budget.
// IT LIVES IN THIS BRANCH, so it exists only with PERF_LOG_EN = 1, exactly like the records it
// shares a port with; with the telemetry compiled out, trace_trig is the constant below and the
// trace keeps its stall trigger alone.
localparam [31:0] TRACE_BURST_QUIET = 32'd50_000_000;   // 1 s at SYS_FREQ
reg [31:0] trace_burst_quiet;
reg        trace_burst_active;
reg        trace_disp_prev, trace_acc_prev;
wire       trace_burst_end = trace_burst_active && (trace_burst_quiet >= TRACE_BURST_QUIET);
wire       trace_store_evt = gvram_grcg_store || gvram_pw_owned;
// THE SECOND TRIGGER IS THE FLIP. Waiting for the game to STOP drawing alone never fires on
// Farland: it makes ~1000 GVRAM accesses per frame at 56.4 fps, so `trace_burst_quiet` never
// reaches its limit, even on a static map screen, the quietest state a running game has. A frame-buffer flip is the event that MARKS a
// redraw, and the ring holds the PAST, so triggering on the flip dumps the drawing that just
// happened. Both `0xA4` (the display page) and `0xA6` (the access page) count, because a game may
// double-buffer with either; each is a one-cycle pulse (the register differs from its own
// previous value) and neither needs a new port - pc9821_crtc already exports the first and
// pc9821_system already carries the second.
//
// THE SAME TIMER ALSO RATE-LIMITS: a flip may fire a dump only when
// TRACE_BURST_QUIET has elapsed since the last one, or a 56 fps flipper would emit a 114 KB dump
// every frame. The quiet arm is KEPT as a fallback for a game that does go idle (between
// dialog advances, for example).
wire       trace_flip_evt = (crtc_o_display_page != trace_disp_prev) ||
                            (gdc_access_page     != trace_acc_prev);
wire       trace_rate_ok  = (trace_burst_quiet >= TRACE_BURST_QUIET);
always @(posedge clk_sys) begin
    if (reset) begin
        trace_burst_quiet  <= 32'd0;
        trace_burst_active <= 1'b0;
        trace_disp_prev    <= 1'b0;
        trace_acc_prev     <= 1'b0;
    end else begin
        trace_disp_prev <= crtc_o_display_page;
        trace_acc_prev  <= gdc_access_page;
        if (trace_store_evt) begin
            trace_burst_quiet  <= 32'd0;
            trace_burst_active <= 1'b1;
        end else if (trace_burst_quiet != TRACE_BURST_QUIET) begin
            trace_burst_quiet <= trace_burst_quiet + 32'd1;
        end
        // One pulse per burst: the next store re-arms it.
        if (trace_burst_end) trace_burst_active <= 1'b0;
        // A flip that passes the rate limit becomes an event and restarts the window.
        if (trace_flip_evt && trace_rate_ok) trace_burst_quiet <= 32'd0;
    end
end
wire trace_flip_trig = trace_flip_evt && trace_rate_ok;
assign trace_trig = trace_burst_end | trace_flip_trig;
// The report's byte order, and the pacing that keeps it from outrunning the FIFO, live in
// pc9821_dbg_record: the three formatters above are pure functions of their index over the
// report's counter snapshot, and the sequencing between them is the part with a handshake and
// its own bench.
pc9821_dbg_record u_dbg_record (
    .clk_sys(clk_sys), .reset(reset),
    .dbg_uart_accept(dbg_uart_accept),
    .wdg_start(wdg_start), .wdg_path(wdg_path), .wdg_char(wdg_char),
    .prf_char(prf_char), .gfx_char(gfx_char),
    .dbg_byte(dbg_uart_byte), .dbg_we(dbg_uart_we), .report_active(dbg_report_active),
    .wdg_idx(wdg_idx), .prf_idx(prf_idx), .gfx_idx(gfx_idx)
);
end else begin : g_no_telemetry
// The telemetry section's only outputs are these two ports: dbg_report_active is read nowhere
// outside it, and every other signal it declares is internal to it.
    // The debug instruments, when any is built: the CD's command log (CDROM_LOG_EN), the display
    // programming log (DBG_GDC_EN) and the CPU instrument (DBG_CPU_EN / DBG_SNOOP_EN / DBG_TRIG_KIND),
    // interleaved by record on the one UART arm. With none built there is no mux, and the arm is
    // the constant it was before the framework existed (the CD log's tie-off).
    localparam DBG_CPU_ANY = DBG_CPU_EN || DBG_SNOOP_EN || (DBG_TRIG_KIND != 0);
    localparam DBG_ANY = CDROM_LOG_EN || DBG_GDC_EN || DBG_FDC_EN || DBG_CPU_ANY;
    if (DBG_ANY) begin : g_dbg
    wire [7:0] gdc_log_byte, cpu_log_byte, fdc_log_byte;
    wire       gdc_log_we, cpu_log_we, gdc_log_accept, cpu_log_accept;
    wire       fdc_log_we, fdc_log_accept;
    if (DBG_GDC_EN) begin : g_gdc_log
    pc9821_gdc_log #(.LOG_CLK_HZ(SYS_FREQ)) u_gdc_log (
        .clk(clk_sys), .rst_n(!reset),
        .io_wr(device_io_wr), .io_addr(device_io_addr), .io_din(device_io_din),
        .vline(crtc_o_vline),
        .tram_we(tram_we), .tram_addr(tram_addr), .tram_din(tram_din),
        .log_byte(gdc_log_byte), .log_we(gdc_log_we), .log_accept(gdc_log_accept)
    );
    end else begin : g_no_gdc_log
    assign gdc_log_byte = 8'h00;
    assign gdc_log_we   = 1'b0;
    end
    if (DBG_FDC_EN) begin : g_fdc_log
    // The floppy controller's log: the iobus's last-access latch (every port the guest touches,
    // with the byte the CPU received for a read), the controller's interrupt line on either
    // window, and its state byte (pc9821_fdc dbg_state).
    pc9821_fdc_log #(.LOG_CLK_HZ(SYS_FREQ)) u_fdc_log (
        .clk(clk_sys), .rst_n(!reset),
        .io_stb(dbg_last_io_stb), .io_wr(dbg_last_io_wr), .io_addr(dbg_last_io_addr),
        .io_data(dbg_last_io_data),
        .fdc_irq(fdc_irq | fdc_irq10), .fdc_state(dbg_fdc_state),
        .log_byte(fdc_log_byte), .log_we(fdc_log_we), .log_accept(fdc_log_accept)
    );
    end else begin : g_no_fdc_log
    assign fdc_log_byte = 8'h00;
    assign fdc_log_we   = 1'b0;
    end
    if (DBG_CPU_ANY) begin : g_cpu_log
    pc9821_dbg_cpu #(
        .LOG_CLK_HZ(SYS_FREQ), .SAMPLER_EN(DBG_CPU_EN ? 1 : 0), .SAMPLE_MS(DBG_SAMPLE_MS),
        .SNOOP_EN(DBG_SNOOP_EN ? 1 : 0), .SNOOP_LO(DBG_SNOOP_LO), .SNOOP_HI(DBG_SNOOP_HI),
        .TRIG_KIND(DBG_TRIG_KIND), .TRIG_ADDR(DBG_TRIG_ADDR), .TRIG_CS(DBG_TRIG_CS),
        .TRIG2_LO(DBG_TRIG2_LO), .TRIG2_HI(DBG_TRIG2_HI), .ARM_S(DBG_ARM_S), .POST(DBG_POST),
        .LAST_MS(DBG_LAST_MS), .TRACE_AW(DBG_TRACE_AW)
    ) u_dbg_cpu (
        .clk(clk_sys), .cpu_cs(cpu_cs), .cpu_eip(cpu_eip), .cpu_pe(cpu_pe), .cpu_vm(cpu_vm),
        .cpu_if(cpu_dbg_eflags[9]), .cpu_intr(z_intr), .cpu_sp(cpu_dbg_SP),
        .cpu_flags(cpu_dbg_eflags[15:0]),
        .inta_ready(inta_ready), .inta_vec(inta_din[7:0]), .vsync_irq(gdc_vsync_irq),
        .io_wr(device_io_wr), .io_rd(device_io_rd), .io_addr(device_io_addr),
        .imr(irq_dbg_imr), .irr(irq_dbg_irr), .isr(irq_dbg_isr),
        .s_imr(irq_dbg_s_imr), .s_isr(irq_dbg_s_isr),
        .ata_block_read(ata_block_read),
        .gate_read(cpu_dbg_gate_read), .gate_addr(cpu_dbg_gate_addr),
        .issue(cpu_dbg_issue), .issue_eip(cpu_dbg_issue_eip),
        // the I/O trigger: every landed access, the FDC's own ports included (the iobus latch)
        .lio_stb(dbg_last_io_stb), .lio_wr(dbg_last_io_wr), .lio_addr(dbg_last_io_addr),
        .lio_data(dbg_last_io_data),
        .m_valid(cpu_mem_valid), .m_ready(mem_cpu_ready), .m_write(z_write), .m_addr({z_addr, 2'b00}),
        .m_be(z_be), .m_burst(z_burstcount), .m_line(z_line_read), .m_wdata(z_dout),
        .m_resp_valid(mem_cpu_resp_valid), .m_rdata(mem_cpu_dout),
        .log_byte(cpu_log_byte), .log_we(cpu_log_we), .log_accept(cpu_log_accept)
    );
    end else begin : g_no_cpu_log
    assign cpu_log_byte = 8'h00;
    assign cpu_log_we   = 1'b0;
    end
    wire [3:0] mux_acc;
    pc9821_dbg_mux #(.N(4)) u_dbg_mux (
        .clk(clk_sys),
        .in_byte({fdc_log_byte, cpu_log_byte, gdc_log_byte, cd_log_byte}),
        .in_we({fdc_log_we, cpu_log_we, gdc_log_we, cd_log_we}), .in_accept(mux_acc),
        .out_byte(dbg_uart_byte), .out_we(dbg_uart_we), .out_accept(dbg_uart_accept)
    );
    assign cd_log_accept  = mux_acc[0];
    assign gdc_log_accept = mux_acc[1];
    assign cpu_log_accept = mux_acc[2];
    assign fdc_log_accept = mux_acc[3];
    end else begin : g_no_dbg
    assign dbg_uart_byte = cd_log_byte;
    assign dbg_uart_we   = cd_log_we;
    assign cd_log_accept = dbg_uart_accept;
    end
    assign trace_trig    = 1'b0;
end
endgenerate
assign mpu_uart_tx = mpu_uart_tx_int;
assign software_reset = triple_fault_reset;

// The PC-9801-86's stereo output, summed from the card's two devices: the OPNA
// (pc9821_opna) and the 86-PCM block (pc9821_pcm86). `z486_mister.sv` crosses it to
// CLK_AUDIO and pc9821_audio_mix mixes it as one slot of pc9821_audio_volume, so
// nothing else is added downstream. The two devices share the slot's gain (vol_voice
// below, in series with the OSD Audio page's PC-9801-86 level), which is right for one
// card: the board as one source. THE SUM IS WIDE AND UNCLAMPED: the two DACs
// (YM2608 FM+SSG and the LC7881) meet at one analog sum whose only clip is the
// output stage, modelled at the FINAL DAC (pc9821_audio_mix's mix_dry saturator).
// An intermediate 16-bit saturation here would flat-top the join whenever FM+SSG
// passed 16 bits, even with a cancelling negative PCM86 sample still to come. The FM+ADPCM sum is clamped once at the jt08_acc junction (ymfm's clamp16
// point, ymfm_opn.cpp:1410-1414); this join carries that clamped junction, the
// AC-coupled (zero-mean) SSG added after it, and PCM86. 20 bits holds the exact range: [+255,996, -239,616].
wire signed [19:0] snd86_l = $signed(opna_snd_l)
                           + $signed({{4{pcm86_snd_l[15]}}, pcm86_snd_l});
wire signed [19:0] snd86_r = $signed(opna_snd_r)
                           + $signed({{4{pcm86_snd_r[15]}}, pcm86_snd_r});
assign sample_86_l = snd86_l;
assign sample_86_r = snd86_r;
// ---------------------------------------------------------------
// The system beeper (the PC speaker)
// ---------------------------------------------------------------
// The machine's own BIOS beeps through this several times during POST, and it is the
// earliest thing the guest can say that is audible with no screen and no serial port.
//
// Two signals ANDed, both the machine's, and one register setting the LEVEL:
//   * TONE is the PIT's CHANNEL 1 output, mode 3 at 2.4576 MHz / divisor. The authentic ITF's
//     own beep routine (BANK4@0x4B2B) writes control 0x76 (channel 1, LSB+MSB, mode 3) and
//     divisor 0x04CD = 1229 -> 2000 Hz through the 0x3FDF/0x3FDB port alias. Channel 2 is the
//     RS-232C baud generator, not the tone.
//   * GATE is system port C bit 3, a MUTE: clear means audible (NP2kai sound/beepc.c:170).
//     The ITF clears it before stage 0x1F and sets it again after (BANK4@0x37F / BANK4@0x3CB).
//   * LEVEL is the software-DIP beeper volume, 0x871E bits [3:2] (beep_vol below): the
//     speaker amplitude in pc9821_audio_mix scales linearly with it and code 0 is an exact mute
//     (NP2kai io/dipsw.c:44-57 writes the code, sound/beepg.c:113-114/161-163 scale by it).
//
// Power-on is silent by construction: port C resets to the value MEASURED on the machine
// (0xB8, bit 3 set) and the PIT's output flip-flop resets to 0.
assign speaker_out = ~beep_mute & pit_out1;
assign vol_master_l = 5'd31;
assign vol_master_r = 5'd31;
// The -86 board reaches the mixer at full scale; pc9821_audio_mix puts the OSD Audio page's
// PC-9801-86 level in series with this code (and the framework's own master volume acts after
// the core). 5'd0 here would mute the slot.
assign vol_voice_l = 5'd31;
assign vol_voice_r = 5'd31;
// THE CD CHANNEL'S GAIN: the mixer sums `vol_en[2] ? cd_l : 0` (pc9821_audio_mix), and cd_l is
// the CD-DA stream scaled by vol_cd. WITHOUT THE CD DRIVE'S PLAYER (CDROM_AUDIO_EN 0) vol_cd is the
// constant 0, so the CD contributes exactly zero. WITH IT, vol_cd is the OSD's "CD audio"
// field (cd_volume_code, decoded by pc9821_osd; the Audio page's CD audio), a user control
// like the volume wheel on a real CD drive, both channels at the same code. Its default (list position 0) is 0 dB, the unity
// level shipped before the field (NP2kai's -6 dB default is a step); the drive's level is still
// uncaptured (todo item 106), which is why it is a control rather than a constant.
// THE CROSSING: cd_volume_code comes from hps_io's status word on clk_sys, and
// pc9821_audio_volume reads vol_cd on CLK_AUDIO. The code is a 5-bit WORD whose neighbouring
// steps flip several bits (28 -> 27 is 11100 -> 11011), so a raw crossing lets one CLK_AUDIO
// edge assemble a code from both (31 = 0 dB on that step). pc9821_audio_mix therefore carries
// vol_cd_l/r into CLK_AUDIO through the held handshake (level_cdc, the A1/A5 mechanism, with
// the Audio page's other two levels), whose clk_sys hold register is this word's one source
// flop; nothing here registers it again (docs/clock-domains.md A7; tb_pc9821_audio_level_cdc).
generate
if (CDROM_AUDIO_EN) begin : g_vol_cd
    assign vol_cd_l = cd_volume_code;
    assign vol_cd_r = cd_volume_code;
end else begin : g_no_vol_cd
    assign vol_cd_l = 5'd0;
    assign vol_cd_r = 5'd0;
end
endgenerate
assign vol_midi_l = 5'd0;
assign vol_midi_r = 5'd0;
assign vol_line_l = 5'd0;
assign vol_line_r = 5'd0;
// The PC speaker's level in the mixer. The framework's own sound.v resets this to 2'h3
// (0 dB) and documents the four steps as -18..0 dB, so 2'd3 is the un-attenuated step: this
// is one of the two places the speaker's level is set, and it is NOT a taste decision. THE
// OTHER PLACE IS the unit of pc9821_audio_mix's beeper ladder (one sounding bit is
// beep_vol * 1024 at the OSD Beeper level's 0 dB; the ancestor's status[19:18] shift that once
// raised it is UNDECLARED in this core's CONF_STR), so a sounding beep is 1,024/2,048/3,072 across the
// 0x871E beeper-volume ladder (code 2 - NP2kai's default - is the historical 2,048; code 0
// is an exact mute), of the +32,767 rail. The LADDER is the machine's register (NP2kai
// io/dipsw.c:44-57 / sound/beepg.c); the ladder's absolute level is a LEVEL decision that
// also depends on the unipolar/AC-coupling convention A-10 leaves open, so it is deliberately
// not changed here.
assign vol_spk = 2'd3;
// vol_en is the mixer's output-switch vector (line_l, line_r, cd_l, cd_r, mic), hard-wired to
// 5'b11111 here exactly as ao486 hard-wires it (ao486_MiSTer rtl/soc/sound/sound.v:321).
assign vol_en = 5'b11111;

always @* begin
    debug_boot_stage = rom_ready ? 3'd2 : (load_error ? 3'd7 : 3'd1);
    debug_sd_error = load_error;
    debug_post_code = io_post_code;
    debug_post_write = io_post_write;
end
assign debug_bios_loaded = rom_ready;
assign debug_first_instruction = cpu_run && z_valid;

// Genuinely unread in this build: the iobus's unmapped-port counters (kept for a
// later diagnostic consumer) and the PS/2 keyboard's clock/data pins, which the
// keyboard does not model (the guest is driven through ps2_key).
wire _unused_ok = &{1'b0, unmapped_writes, unmapped_reads, last_unmapped_port,
                    ps2_kbclk_in, ps2_kbdat_in};

endmodule

`default_nettype wire
