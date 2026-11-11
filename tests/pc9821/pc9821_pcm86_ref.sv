// TEST REFERENCE: a frozen copy of src/pcm86/pc9821_pcm86.sv before its area rewrite, kept as the equivalence reference of tb_pc9821_pcm86_equiv; not maintained.
// The PC-9801-86's 86-PCM block: the half of the card that is not the YM2608 (src/opna/).

// A register file plus a 32 KiB circular sample buffer fed through ONE write-only byte port.
// Nothing here is addressable: the guest writes bytes to 0xA46C and this block keeps its own
// write pointer, read pointer and count, draining at the selected rate. Its only views are
// 0xA466's full/empty bits and the 0xA468 interrupt; its only control is 0xA468's bit-3 buffer
// reset. 0xA460 is the card's extend/ID register and belongs to pc9821_iobus, not here.

// Three rules, all from the references and NONE measured - never probed (probe 0):
//   * 16-bit samples are SIGNED and stored HIGH BYTE FIRST, not little-endian; 8-bit samples
//     are SIGNED and left-justified. A first implementation gets both wrong.
//   * 0xA468 bits 2:0 index a table that is EIGHT TIMES the sample rate. Index 0 is 44100 Hz
//     and the reset value; index 6 is the references' 44010, not the 44100/8 the pattern gives.
//   * 0xA466 bit 0 is one HIGH/LOW pair per SAMPLE period and FREE-RUNS while playback is
//     disabled, because a driver calibrates on it before starting playback.

// Every port rule is NP2kai's (cbus/pcm86io.c, sound/pcm86c.c), reproduced independently by
// qemu-pc98; where the two disagree NP2kai is the model and each divergence is called out at
// the port it affects.

`default_nettype none

module pc9821_pcm86_ref #(
    parameter integer SYS_CLOCK_HZ = 50_000_000
) (
    input  wire        clk,
    input  wire        reset,        // synchronous, active high

    // Device bus, driven by pc9821_iobus. Only the even ports 0xA462-0xA46E
    // are routed here (pc9821_system's pcm_cs); the odd partners stay open bus
    // as separate port values, exactly as NP2kai leaves them.
    input  wire [15:0] io_addr,
    input  wire        io_wr,
  /* verilator lint_off UNUSEDSIGNAL */  // the read strobe is not needed: reads are
  input  wire        io_rd,               // answered from registers on the address alone
                                         // (see io_rd_wait below), so only io_wr is used
  /* verilator lint_on UNUSEDSIGNAL */
    input  wire  [7:0] io_din,
    output reg   [7:0] io_dout,
    output wire        io_rd_wait,
    // Write back-pressure for the 0xA46C stream: high while the buffer's write
    // FIFO cannot accept a byte. pc9821_iobus holds the guest's I/O access until
    // it clears, so a full-speed 0xA46C burst (REP OUTSB at the IO_MIN_HOLD floor,
    // one byte per ~10 clk_sys) against SDRAM contention stalls the CPU instead of
    // silently dropping sample bytes (clicks). See pc9821_pcm86_buf_ref.sv.
    output wire        io_wr_wait,

    // Stereo output, already scaled by the 0xA466 volume. Held between samples
    // (zero-order hold), forced to silence while playback is disabled, and ZEROED
    // on an under-run -- a sample period the buffer cannot supply a whole frame
    // (count < nbytes, the references' own "effectively empty" level). All three
    // are what both references do: neither keeps the last sample on the output
    // when 0xA468 bit 7 is clear, and neither repeats it when the buffer is dry
    // (NP2kai zeroes smp/lastsmp on every *_bufempty path, sound/pcm86g.c:105-109,
    // :188-194, :259-263, :341-347; qemu sets pcm_last_l/r = 0 in
    // opna_pcm_consume, hw/audio/pc98-opna.c:289-325).
    output wire signed [15:0] snd_l,
    output wire signed [15:0] snd_r,

    // The buffer-low interrupt, the wire form of NP2kai's interrupt query
    // (pcm86gen_intrq, sound/pcm86c.c:465-490): the IRQ enable bit 5 AND (the
    // latched flag OR the live buffer-low level). It is LOW while the guest
    // masks it and rises AGAIN on a re-enable with the flag still latched,
    // which is the fresh edge the edge-latched PIC consumes
    // (pc9821_pic.sv:172 `ir_set = ir_in & ~ir_prev`). The guest clears the
    // latched flag by writing 0xA468 with bit 4 clear. On the card one strap
    // feeds the OPNA's timers and this block, so pc9821_system puts this and
    // the OPNA's IRQ line on one 8259 input (pc9821_irq_share) rather than
    // giving the two devices different interrupt numbers.
    output wire        irq,

    // The logical byte count, for the bench. The card has no port that exposes
    // it -- 0xA466's two bits are the whole software view -- so the test asserts
    // this instead of inferring the level from a timing.
    output wire [15:0] dbg_count,

    // The sample buffer's SDRAM backing (src/pcm86/pc9821_pcm86_buf_ref.sv). The buffer used
    // to be 32 M10K blocks inferred inside this module; it now lives in SDRAM on the
    // memory controller's third port, which this design used to leave tied off. The
    // interface above is unchanged -- only where the bytes are stored moved.
    input  wire [31:0] buf_base,
    output wire        sdram_valid,
    input  wire        sdram_ready,
    output wire        sdram_write,
    output wire [31:0] sdram_addr,
    output wire [31:0] sdram_din,
    input  wire [31:0] sdram_dout,
    input  wire        sdram_resp_valid,
    output wire  [3:0] sdram_be,
    output wire  [7:0] sdram_burstcount
);

  // ------------------------------------------------------------------
  // Ports. The four modelled ones are named; the other four even ports of the
  // block are decoded but deliberately not given behaviour (see io_dout).
  // ------------------------------------------------------------------
  localparam [15:0] P_SPARE0 = 16'h0A462;
  localparam [15:0] P_SPARE1 = 16'h0A464;
  localparam [15:0] P_VOLUME = 16'h0A466;
  localparam [15:0] P_FIFO   = 16'h0A468;
  localparam [15:0] P_DAC    = 16'h0A46A;
  localparam [15:0] P_DATA   = 16'h0A46C;
  localparam [15:0] P_SPARE2 = 16'h0A46E;

  wire wr_vol  = io_wr && (io_addr == P_VOLUME);
  wire wr_fifo = io_wr && (io_addr == P_FIFO);
  wire wr_dac  = io_wr && (io_addr == P_DAC);
  wire wr_data = io_wr && (io_addr == P_DATA);

  // The guest's buffer reset: 0xA468 bit 3's 0->1 edge (NP2kai cbus/pcm86io.c:91
  // `xchgbit = fifo ^ val`, then `val & 8`).
  //
  // IT MUST BE THE LAST WORD ON THE STATE IT OWNS. The drain engine's case and
  // the data write's pointer update appear LATER in the same always block, so on
  // a cycle where one of them coincides with this edge their assignments win and
  // the reset is silently PARTIAL. That is not hypothetical and it is not rare in
  // the case that matters: a driver resets the buffer to FLUSH one that is
  // playing, and tb_pc9821_pcm86_bufrst measures 6 of the 1134 cycles of a
  // 44.1 kHz sample period leaving the count at 0xFFFE -- the reset had already
  // zeroed it and the in-flight frame's completion then subtracted a frame from
  // zero. The count is what the driver reads back as full/empty, so a partial
  // reset leaves the status lying to the driver that asked for the flush.
  //
  // NP2kai's handler cannot be undone this way: its reset and its generator are
  // separate call sites, so the reset always stands.
  wire buf_rst = wr_fifo && io_din[3] && !fifo[3];

  // Reads are answered from registers, so the block never asks for the extra
  // bus cycle the GDC and the OPNA's registered chip output need.
  assign io_rd_wait = 1'b0;

  // The write back-pressure (S6), for the 0xA46C stream. The decode is the
  // 4-port WINDOW 0xA468-0xA46F, not 0xA46C alone: the bus presents the FIRST
  // lane's address before the access, and a word/dword OUT whose lanes straddle
  // 0xA46C (first lane 0xA469-0xA46B) must stall before its 0xA46C lane reaches
  // the FIFO. Over-stalling the window's other ports while the FIFO is full is
  // extra latency, never a loss (and the stall always ends: the SDRAM drain pops
  // without the guest). pc9821_iobus gates this with request_write, so reads
  // -- including the 0xA46C pcm86_inpdummy read -- pass unwaited. The window is
  // the term's own bound: pc9821_system must NOT re-qualify it with pcm_cs,
  // which excludes the odd first lanes the window exists for.
  wire buf_wr_wait;   // the buffer's write FIFO is full (u_buf below)
  assign io_wr_wait = (io_addr[15:2] == P_DATA[15:2]) && buf_wr_wait;

  // ------------------------------------------------------------------
  // The sample-rate phase accumulator. step = 2^32 * f_sample / clk_sys, so the
  // MSB of the accumulator is the sample strobe and its next bit is the phase
  // the guest watches at 0xA466 bit 0. 536870912 is 2^32/8, which keeps the
  // reference's rate table (x8 the sample rate) in the expression.
  // ------------------------------------------------------------------
  /* verilator lint_off WIDTHEXPAND */  // the 64-bit product is REQUIRED, not incidental:
  /* verilator lint_off WIDTHTRUNC */   // 536870912 * 352800 overflows 32 bits before the
                                        // divide, and the quotient is at most ~3.8e6, far
                                        // inside the 32 the localparam keeps. Narrowing
                                        // either width would change the rate silently.
  localparam [31:0] STEP0 = (64'd536_870_912 * 64'd352800) / SYS_CLOCK_HZ;
  localparam [31:0] STEP1 = (64'd536_870_912 * 64'd264600) / SYS_CLOCK_HZ;
  localparam [31:0] STEP2 = (64'd536_870_912 * 64'd176400) / SYS_CLOCK_HZ;
  localparam [31:0] STEP3 = (64'd536_870_912 * 64'd132300) / SYS_CLOCK_HZ;
  localparam [31:0] STEP4 = (64'd536_870_912 * 64'd88200)  / SYS_CLOCK_HZ;
  localparam [31:0] STEP5 = (64'd536_870_912 * 64'd66150)  / SYS_CLOCK_HZ;
  localparam [31:0] STEP6 = (64'd536_870_912 * 64'd44010)  / SYS_CLOCK_HZ;
  localparam [31:0] STEP7 = (64'd536_870_912 * 64'd33075)  / SYS_CLOCK_HZ;
  /* verilator lint_on WIDTHEXPAND */
  /* verilator lint_on WIDTHTRUNC */

  /* verilator lint_off UNUSEDSIGNAL */  // bit 4 is STORED and never read, correctly: the
  reg [7:0]  fifo;       // 0xA468: b2:0 rate, b3 buffer reset, b4 IRQ clear
  /* verilator lint_on UNUSEDSIGNAL */  // IRQ clear tests the WRITTEN byte (io_din[4],
                                        // below) and the read-back substitutes irq_pending
                                        // for it - both matching NP2kai, which masks ~0x10
                                        // on read (pcm86io.c:303) and tests val & 0x10
                                        // on write (:114)
  reg [7:0]  dactrl;     // 0xA46A when 0xA468 bit 5 is clear
  reg [15:0] fifosize;   // 0xA46A when 0xA468 bit 5 is set: the IRQ threshold
  reg [3:0]  vol5;       // 0xA466: DAC volume, (~val) & 0xF when (val & 0xE0)==0xA0

  reg        irq_pending;  // reported at 0xA468 bit 4
  reg        irq_arm;      // set by each data write, cleared when the IRQ fires

  reg [31:0] phase;
  reg [14:0] wrptr, rdptr;
  reg [15:0] count;        // 0x8000 = the 32 KiB logical buffer is full
  reg signed [15:0] hold_l, hold_r;

  wire [2:0]  rate_sel = fifo[2:0];
  reg  [31:0] step;

  always @* begin
    case (rate_sel)
      3'd0:    step = STEP0;
      3'd1:    step = STEP1;
      3'd2:    step = STEP2;
      3'd3:    step = STEP3;
      3'd4:    step = STEP4;
      3'd5:    step = STEP5;
      3'd6:    step = STEP6;
      default: step = STEP7;
    endcase
  end

  wire [32:0] phase_sum   = {1'b0, phase} + {1'b0, step};
  wire        sample_tick = phase_sum[32];
  // One HIGH/LOW pair per sample period (NP2kai pcm86_ia466).
  wire        phase_bit   = phase[31];

  // ------------------------------------------------------------------
  // Sample format. frame_bytes = 1 << pcm86bits[fmt] with
  // pcm86bits[] = {1,1,1,2,0,0,0,1}, i.e. 2,2,2,4,1,1,1,2 bytes per frame
  // (qemu's opna_pcm_frame_bytes is the same table).
  // ------------------------------------------------------------------
  function automatic [2:0] frame_bytes(input [2:0] fmt);
    begin
      case (fmt)
        3'd0, 3'd1, 3'd2: frame_bytes = 3'd2;   // 16-bit
        3'd3:            frame_bytes = 3'd4;   // 16-bit stereo
        3'd4, 3'd5, 3'd6: frame_bytes = 3'd1;  // 8-bit
        default:         frame_bytes = 3'd2;   // 8-bit stereo
      endcase
    end
  endfunction

  wire [2:0] fmt_sel = dactrl[6:4];
  wire [2:0] nbytes  = frame_bytes(fmt_sel);

  wire buf_full  = (count >= 16'h8000);
  // NP2kai's "effectively empty" widening: virbuf <= stepmask, i.e. fewer bytes
  // than one sample frame (qemu's `count < frame_bytes` is the same test).
  wire buf_empty = (count < {13'd0, nbytes});

  // ------------------------------------------------------------------
  // The 32 KiB buffer: one write port (the guest's 0xA46C byte) and one read
  // port (the drain engine), both on clk. It is block RAM, not registers --
  // 32,768 bytes, which is why the design report puts it in M10K and not in the
  // SDRAM window the OPNA's ADPCM-B RAM needs.
  //
  // The drain engine's state is declared here because the buffer's read enable
  // is derived from it.
  // ------------------------------------------------------------------
  // The engine is a REQUEST/VALID handshake now, not a one-cycle block-RAM read: the buffer
  // is in SDRAM (src/pcm86/pc9821_pcm86_buf_ref.sv), so a read takes the controller's latency
  // rather than one cycle, and D_WAIT is where the engine rides it out. A frame is <=4
  // bytes against a 1134-clk strobe period, so the extra states are free.
  localparam [1:0] D_IDLE = 2'd0, D_REQ = 2'd1, D_WAIT = 2'd2, D_DONE = 2'd3;

  reg  [1:0]  dstate;
  reg  [14:0] rd_addr;
  wire [7:0]  rd_q;

  // The read request strobe: asserted for the one cycle of D_REQ. The buffer latches it and
  // answers with rd_valid (the SDRAM round trip), which D_WAIT holds for.
  wire rd_req = (dstate == D_REQ);
  wire rd_valid;

  assign dbg_count = count;

  pc9821_pcm86_buf_ref u_buf (
    .clk(clk), .reset(reset), .buf_base(buf_base),
    // The guest's write: a one-cycle strobe at wrptr, the address BEFORE the pointer advances --
    // exactly where the block-RAM port A landed it. wr_wait back-pressures it (io_wr_wait).
    .wr_en(wr_data), .wr_addr(wrptr), .wr_data(io_din), .wr_wait(buf_wr_wait),
    // The drain engine's read, as a request/valid handshake.
    .rd_req(rd_req), .rd_addr(rd_addr), .rd_data(rd_q), .rd_valid(rd_valid),
    .sdram_valid(sdram_valid), .sdram_ready(sdram_ready), .sdram_write(sdram_write),
    .sdram_addr(sdram_addr), .sdram_din(sdram_din), .sdram_dout(sdram_dout),
    .sdram_resp_valid(sdram_resp_valid), .sdram_be(sdram_be),
    .sdram_burstcount(sdram_burstcount)
  );

  // ------------------------------------------------------------------
  // The drain engine. One sample frame per sample strobe, while 0xA468 bit 7
  // (playback enable) is set and the buffer holds a whole frame. The read port
  // is registered, so a frame takes two cycles per byte: present the address,
  // capture what the block RAM registered. A frame is therefore at most 8 clk
  // against a strobe period of 1134 clk at 50 MHz and 44.1 kHz, so the engine
  // always finishes long before the next strobe.
  // ------------------------------------------------------------------
  reg [1:0]  bidx;
  reg [2:0]  nbyte_rg;
  reg [31:0] acc;

  // Decode of the captured frame. Byte 0 of a frame is its HIGH byte for a
  // 16-bit sample (big-endian, high byte first), and an 8-bit sample is
  // left-justified in a 16-bit word, so a frame's bytes shifted into `acc` from
  // the left land as byte0 in the top byte of the field the mode reads.
  reg signed [15:0] frame_l, frame_r;

  always @* begin
    case (fmt_sel)
      3'd0: begin frame_l = 16'sd0;                  frame_r = 16'sd0;                  end
      3'd1: begin frame_l = 16'sd0;                  frame_r = acc[15:0];               end
      3'd2: begin frame_l = acc[15:0];               frame_r = 16'sd0;                  end
      3'd3: begin frame_l = acc[31:16];              frame_r = acc[15:0];               end
      3'd4: begin frame_l = 16'sd0;                  frame_r = 16'sd0;                  end
      3'd5: begin frame_l = 16'sd0;                  frame_r = {acc[7:0], 8'h00};       end
      3'd6: begin frame_l = {acc[7:0], 8'h00};       frame_r = 16'sd0;                  end
      default: begin frame_l = {acc[15:8], 8'h00};   frame_r = {acc[7:0], 8'h00};       end
    endcase
  end

  // DAC volume. NP2kai's vol5 = (~val) & 0xF when (val & 0xE0) == 0xA0, and
  // both references scale the sample linearly by it (qemu: sample * volume / 15,
  // unity at 15). 4369 = round(65536/15), so the reciprocal multiply is the /15
  // law to within an LSB and needs no divider. Reset value 0: NP2kai's reset
  // memsets vol5, so an out-of-reset card is SILENT until 0xA466 is programmed,
  // which is a register contract rather than an accident.
  wire [15:0] vol_scale = {12'd0, vol5} * 16'd4369;
  /* verilator lint_off UNUSEDSIGNAL */  // Q16 scaling: the DAC takes the TOP 16 bits,
  wire signed [31:0] l_scaled = hold_l * $signed({1'b0, vol_scale});   // so the low half is
  wire signed [31:0] r_scaled = hold_r * $signed({1'b0, vol_scale});   // the fraction
  /* verilator lint_on UNUSEDSIGNAL */

  assign snd_l = fifo[7] ? l_scaled[31:16] : 16'sd0;
  assign snd_r = fifo[7] ? r_scaled[31:16] : 16'sd0;

  // ------------------------------------------------------------------
  // The interrupt. It is raised when the buffer has fallen to the 0xA46A
  // threshold after a data write, on NP2kai's path (pcm86gen_intrq /
  // pcm86_cb: armed by the write, fires when virbuf <= fifosize) and qemu's
  // (armed on each 0xA46C write, fires once when count <= threshold). It is a
  // level at 0xA468 bit 4 and is cleared by a 0xA468 write with bit 4 clear,
  // which is the only way software clears it.
  //
  // NP2kai's undocumented heuristics (none is hardware evidence): the write-to-interrupt delay ("no basis for the value",
  // sound/pcm86c.c:469-472) and the irq-clear-with-empty-buffer long wait
  // (cbus/pcm86io.c:117-120) are NOT modelled here. The forced interrupt for
  // Policenauts (cbus/pcm86io.c:122-127) is PARTIALLY modelled: the re-assert
  // at the write block below is a gated SUBSET of it (only on a bit-4-clear
  // write, only where the OLD enable bit and level hold), where NP2kai's runs
  // on EVERY 0xA468 write regardless of val bit 4 and the enable. One
  // guest-visible divergence of that subset: NP2kai's 0x90 write at a true
  // level actively SETS irqflag (pcm86io.c:123-125), so mask-at-low-level ->
  // refill -> re-enable delivers an interrupt there and not here. Aligning it
  // is a separate fail-first change.
  // ------------------------------------------------------------------
  wire irq_set = irq_arm && fifo[5] && (count <= fifosize);

  // The interrupt QUERY, one signal for both views of it. NP2kai's
  // pcm86gen_intrq is enable-bit-5 AND (the latched irqflag OR the live
  // virbuf <= fifosize level): FALSE the moment !(fifo & 0x20)
  // (sound/pcm86c.c:472-475), TRUE off the latched flag (:476-479) or the live
  // level, which it latches (:480-486). That same query is 0xA468 bit 4's
  // read-back (cbus/pcm86io.c:299-308) and the query TERM of NP2kai's
  // interrupt delivery (sound/opntimer.c:86-101, 125-140 feed pcm86gen_intrq(1)
  // into intreq). The wire is that QUERY - not a claim that every NP2kai
  // delivery path is gated by it: opntimer.c:88-89 and :127-128 additionally
  // force intreq = TRUE from the RAW irqflag (bypassing pcm86gen_intrq and its
  // enable gate) whenever the FM status bit is clear, and pcm86c.c:145-163
  // (pcm86_cb) calls pic_setirq with no gate at all. Those two are unmodelled
  // NP2kai DELIVERY divergences, recorded with the heuristics above.
  // A wire driven by irq_pending alone is NOT that query: it stays HIGH through
  // an 0xA468 write of 0x90 (bit 5 clear, bit 4 set, so the latch survives -
  // cbus/pcm86io.c:114-121) and eats the re-enable's rising edge at the PIC
  // (pc9821_pic.sv:168; wired in through pc9821_system.sv:1533, `.irq_a(opna_irq), .irq_b(pcm86_irq),`). tb_pc9821_pcm86_irqmask.
  wire irq_query = (irq_pending || (count <= fifosize)) && fifo[5];

  // EVERY ARMED THRESHOLD EVENT IS A FRESH REQUEST. NP2kai delivers each one with its own
  // pic_setirq (sound/pcm86c.c pcm86_cb: `pcm86->irqflag = 1; ... pic_setirq(pcm86->irq);`),
  // but this wire is a level into an edge-latched PIC (pc9821_pic.sv `ir_set = ir_in &
  // ~ir_prev`). When the line is ALREADY high as an event fires - an ISR that acknowledged
  // while the buffer was still at the threshold (the flag re-latches, pcm86_oa468's force)
  // and then refilled - the event made no edge, the next interrupt never came and playback
  // stalled. The producer's own one-cycle bubble (SCED R6) drops the line for exactly the
  // cycle after such an event, so the PIC sees the new rising edge. irq_line_q is the line
  // as it stood BEFORE the event's cycle: a first event from a low line rises once, unbubbled.
  // tb_pc9821_pcm86_irq_rearm.
  reg irq_line_q;
  reg irq_bubble;
  assign irq = irq_query && !irq_bubble;

  // ------------------------------------------------------------------
  // Port reads.
  // ------------------------------------------------------------------
  always @* begin
    case (io_addr)
      // 0xA466: bit 7 full, bit 6 empty, bit 0 the sample phase, bits 5:1 read
      // 0 (pcm86_ia466; qemu's layout is identical).
      P_VOLUME: io_dout = {buf_full, buf_empty, 5'b00000, phase_bit};
      // 0xA468: the control byte with bit 4 replaced by the interrupt flag.
      // NP2kai pcm86_ia468 answers `(fifo & ~0x10) | (pcm86gen_intrq(0) << 4)`
      // (cbus/pcm86io.c:299-308), and pcm86gen_intrq returns FALSE when the IRQ
      // enable bit 5 is clear, else TRUE when the latched irqflag is set OR the
      // live `virbuf <= fifosize` level holds (sound/pcm86c.c:465-495). So bit 4
      // is (latched flag || live level) && enable.
      P_FIFO:   io_dout = {fifo[7:5], irq_query, fifo[3:0]};
      // 0xA46A: the DAC control register reads back verbatim. A threshold write
      // (0xA468 bit 5 set) does not move it: the port has two meanings and only
      // one of them is visible at a time (pcm86_ia46a).
      P_DAC:    io_dout = dactrl;
      // The four even ports of the block this core does not model: 0xA462 and
      // 0xA464 are the WaveStar/CS4231 magic-sequence ports on a DIFFERENT card
      // (NP2kai attaches no write for them in 86 mode and a dummy read), 0xA46C
      // is write-only in both references, and 0xA46E is unattached in 86 mode.
      // They are decoded here so the block's traffic stops being counted as
      // unmapped (the boot-stop U= instrument). NP2kai attaches pcm86_inpdummy
      // to all four (cbus/pcm86io.c:342-346, at :433-434,483-484,489-490) and it
      // returns 0, so the primary reference answers 0x00 where the open-bus
      // default was 0xFF.
      // The Xe10's read bytes (docs/probes/XE10T-XE10-AUDIT.TXT BA462/BA464/BA46C/BA46E), applied to
      // this reference copy as to pc9821_pcm86.sv: a read-value change both sides carry, not a rewrite.
      P_SPARE0, P_SPARE1, P_SPARE2: io_dout = 8'hFF;
      P_DATA:   io_dout = 8'hEE;
      default:  io_dout = 8'hFF;
    endcase
  end

  // ------------------------------------------------------------------
  // Register writes and the engine.
  // ------------------------------------------------------------------
  always @(posedge clk) begin
    if (reset) begin
      fifo        <= 8'h00;
      // NP2kai's reset: dactrl 0x32 (16-bit stereo), threshold 0x80.
      dactrl      <= 8'h32;
      fifosize    <= 16'h0080;
      vol5        <= 4'h0;
      irq_pending <= 1'b0;
      irq_arm     <= 1'b0;
      phase       <= 32'd0;
      wrptr       <= 15'd0;
      rdptr       <= 15'd0;
      count       <= 16'd0;
      hold_l      <= 16'sd0;
      hold_r      <= 16'sd0;
      dstate      <= D_IDLE;
      bidx        <= 2'd0;
      nbyte_rg    <= 3'd0;
      acc         <= 32'd0;
      rd_addr     <= 15'd0;
      irq_line_q  <= 1'b0;
      irq_bubble  <= 1'b0;
    end else begin
      irq_line_q <= irq;
      irq_bubble <= irq_set && irq_line_q;
      // The phase accumulator free-runs (see the header): a driver calibrates
      // the card by watching 0xA466 bit 0 before it enables playback.
      phase <= phase_sum[31:0];

      // ---- 0xA466: volume, when the top three bits say it is the volume ----
      if (wr_vol && (io_din[7:5] == 3'b101))
        vol5 <= ~io_din[3:0];

      // ---- 0xA468: mode/control ----
      if (wr_fifo) begin
        // Bit 3 is a buffer reset on the 0->1 EDGE. It clears both pointers, the
        // count, the rate accumulator and the held sample, and abandons a frame
        // in flight. The `!buf_rst` guards below keep a draining frame and a
        // data write from undoing it (see buf_rst's declaration).
        if (buf_rst) begin
          wrptr   <= 15'd0;
          rdptr   <= 15'd0;
          count   <= 16'd0;
          phase   <= 32'd0;
          hold_l  <= 16'sd0;
          hold_r  <= 16'sd0;
          irq_arm <= 1'b0;
          dstate  <= D_IDLE;
        end
        fifo <= io_din;
      end

      // ---- 0xA46A: threshold or DAC control, multiplexed by 0xA468 bit 5 ----
      if (wr_dac) begin
        if (fifo[5]) begin
          // (val + 1) << 7 bytes, with 0xFF meaning 0x7FFC. The 128-byte
          // granularity and the 0x7FFC ceiling are the driver-visible statement
          // of the buffer's size.
          fifosize <= (io_din == 8'hFF) ? 16'h7FFC
                                        : ({8'd0, io_din} + 16'd1) << 7;
        end else if (io_din[3:0] != 4'hF) begin
          // The low nibble's meaning is unknown. The guard above is NP2kai's own,
          // verbatim - pcm86_oa46a (cbus/pcm86io.c:155-160) returns early on
          // `(val & 0xf) == 0xf` under the comment
          // "WORKAROUND: for WinNT 3.5, reject abnormal settings" (translated).
          // IT IS A WORKAROUND, NOT HARDWARE EVIDENCE: NP2kai labels it as one
          // itself, no datasheet or capture says the card rejects 0x?F, and this
          // core keeps it only because it is harmless and the reference has it.
          // Do not cite this line as reference-backed
          // hardware behaviour. NP2kai's OTHER 86-PCM heuristics are still NOT
          // modelled here and must not be smuggled in through this comment: the
          // write-to-interrupt delay ("no basis for the value",
          // sound/pcm86c.c:120-122) and the irq-clear-with-empty-buffer long wait
          // (cbus/pcm86io.c:113-118).
          dactrl <= io_din;
        end
      end

      // ---- 0xA46C: the sample data port ----
      // Suppressed on a reset cycle: the reset has just zeroed wrptr and count,
      // and this block's updates would advance them past it. The byte itself is
      // still stored, because the buffer's write enable is the combinational
      // wr_data -- it lands at the pre-reset wrptr, which is about to be zero.
      if (wr_data && !buf_rst) begin
        wrptr <= wrptr + 15'd1;
        // A byte is accepted even when the 32 KiB buffer is full; the oldest
        // bytes are dropped, so the newest data survives.
        // NP2kai appends past full into a rescue margin (PCM86_REALBUFSIZE =
        // 0x8000 + rescue, an artifact of its 64 KiB host ring) that this ring
        // does not have; the slip granularity below is its.
        // THE SLIP IS A WHOLE 4-BYTE GROUP, NOT ONE BYTE (NP2kai pcm86_oa46c:
        // `g_pcm86.realbuf -= 4; g_pcm86.readpos = (g_pcm86.readpos + 4) & PCM86_BUFMSK;`).
        // 4 is a multiple of every format's frame (1, 2 or 4 bytes), so the drain stays
        // frame-aligned; a 1-byte slip swapped L/R and split samples for the rest of the
        // session (tb_pc9821_pcm86_overflow_align). The newest byte joins and the four
        // oldest leave: 0x8000 + 1 - 4.
        if (count == 16'h8000) begin
          rdptr <= rdptr + 15'd4;
          count <= 16'h7FFD;
        end else
          count <= count + 16'd1;
        irq_arm <= 1'b1;
      end

      // ---- the drain engine ----
      // Gated off on a reset cycle so it cannot overwrite what the reset just
      // assigned. See buf_rst.
      if (!buf_rst) case (dstate)
        // One decision per SAMPLE PERIOD: play a frame, or UNDER-RUN to silence.
        D_IDLE: if (sample_tick && fifo[7]) begin
          if (count >= {13'd0, nbytes}) begin
            bidx     <= 2'd0;
            nbyte_rg <= nbytes;
            acc      <= 32'd0;
            rd_addr  <= rdptr;
            dstate   <= D_REQ;
          end else begin
            // UNDER-RUN: the buffer cannot supply a whole frame this period, so the
            // DAC outputs SILENCE, not the frame before it. The zero-order hold is
            // only for the gap BETWEEN frames; both references throw their sample
            // state away when the buffer is dry (NP2kai's four *_bufempty labels:
            // `smp = 0; lastsmp = 0;` -- sound/pcm86g.c:105-109, :188-194,
            // :259-263, :341-347; qemu: `pcm_last_l = l;` with l = 0 in
            // opna_pcm_consume, hw/audio/pc98-opna.c:289-325). Holding the last
            // frame instead leaves a stuck DC level while playback stays enabled,
            // which is a permanent headroom loss on one rail at the final DAC's
            // single clamp.
            hold_l <= 16'sd0;
            hold_r <= 16'sd0;
          end
        end
        // D_REQ asserts rd_req for one cycle; the buffer latches the address here.
        D_REQ: dstate <= D_WAIT;
        // D_WAIT holds until the SDRAM read answers. The byte arrives with rd_valid.
        D_WAIT: if (rd_valid) begin
          acc <= {acc[23:0], rd_q};
          if (bidx == nbyte_rg[1:0] - 2'd1) begin
            dstate <= D_DONE;
          end else begin
            bidx    <= bidx + 2'd1;
            rd_addr <= rdptr + {13'd0, bidx} + 15'd1;
            dstate  <= D_REQ;
          end
        end
        default: begin  // D_DONE
          // A guest write can land on this SAME cycle. On the card the write port and the
          // drain are different ports and both take effect; here the write block above is
          // overwritten by this one, so its pointer work is folded back in by hand.
          // Without this a byte written as a frame completed was LOST
          // (tb_pc9821_pcm86_bufrst's write sweep found it once the drain's timing moved:
          // count 2497 -> 2495).
          //   The fold is the SERIALIZED order NP2kai always sees (its drain runs at
          // sound_sync, before the port write is handled): the frame leaves first, so the
          // buffer is no longer full when the byte arrives and no slip is owed. The byte
          // lands in the slot the frame just vacated and count is old - nbyte + 1, which
          // never exceeds 0x8000. count == (wrptr - rdptr) mod 0x8000 holds either way.
          rdptr  <= rdptr + {12'd0, nbyte_rg};
          count  <= count - {13'd0, nbyte_rg}
                  + ((wr_data && !buf_rst) ? 16'd1 : 16'd0);
          hold_l <= frame_l;
          hold_r <= frame_r;
          dstate <= D_IDLE;
        end
      endcase

      // NP2kai pcm86_oa468 ordering (cbus/pcm86io.c:105-126): the clear runs
      // FIRST, then the still-true level condition re-asserts the flag. A
      // bit-4-clear write therefore cannot extinguish a buffer that is still at
      // or below the threshold; it only sticks when the level is no longer true
      // (or the IRQ is disabled). The re-assert uses the same enable bit as
      // irq_set, so a disabled interrupt stays cleared. It is the gated subset
      // of NP2kai's Policenauts force (cbus/pcm86io.c:122-127) the heuristics
      // note above records - NP2kai's is unconditional in val bit 4 and the
      // enable.
      if (wr_fifo && !io_din[4])
        irq_pending <= 1'b0;
      if (irq_set) begin
        irq_pending <= 1'b1;
        irq_arm     <= 1'b0;
      end
      if (wr_fifo && !io_din[4] && fifo[5] && (count <= fifosize))
        irq_pending <= 1'b1;
    end
  end

endmodule

`default_nettype wire
// The PC-9801-86 86-PCM sample buffer, backed by SDRAM instead of 32 M10K blocks.
//
// The 32 KiB circular buffer in pc9821_pcm86_ref.sv cost 32 M10K blocks. Those blocks are the
// design's scarcest resource after the GVRAM, and the resource audit named this buffer as the
// one block-RAM consumer whose access rate tolerates the SDRAM read latency. So it moves to
// the memory controller's THIRD port, which this design otherwise leaves tied off.
//
// LATENCY IS AFFORDABLE because the drain reads at most 4 bytes per sample frame against a
// 1134-clk frame period (50 MHz / 44.1 kHz), so its read is a REQUEST/VALID handshake here
// rather than the one-cycle block-RAM read it replaced.
//
// THE WRITE NEEDS A FIFO because the guest's 0xA46C write is a one-cycle strobe and an SDRAM
// write takes several. Back-to-back 0xA46C writes reach the FIFO every ~10-15 clk_sys at the
// IO_MIN_HOLD=4 I/O cadence (a tight loop or REP OUTSB), which can outrun a contended SDRAM
// round trip for a burst -- the old "at most once per I/O access (~186 clk)" sizing claim
// predates that speedup. So the FIFO is BACK-PRESSURED, not sized: wr_wait rises while it is
// full and pc9821_pcm86_ref/pc9821_iobus hold the CPU's I/O write in the bus's S_IOWAIT state
// until there is room, so a guest byte is never dropped. This module is a byte-addressed
// 2^15-byte memory and knows nothing about sample format -- the format is pc9821_pcm86_ref.sv's.

`default_nettype none

module pc9821_pcm86_buf_ref (
    input  wire        clk,
    input  wire        reset,

    // Byte address of the buffer's first byte in the SDRAM (4-byte aligned). An input
    // rather than a parameter because it moves with the guest RAM size: pack_base +
    // PACK_BYTES + 256 KiB.
    input  wire [31:0] buf_base,

    // Guest write port. wr_en is a one-cycle strobe; wr_addr/wr_data are valid on it.
    // wr_wait is the write back-pressure: high while the FIFO cannot accept a byte.
    // The master (pc9821_iobus, through pc9821_pcm86_ref's io_wr_wait) holds the guest's
    // I/O access until it clears, so the 0xA46C stream can run at the IO_MIN_HOLD
    // floor (one byte per ~10-15 clk) against SDRAM contention WITHOUT dropping
    // bytes; `fifo_push` keeps its !full guard as the last resort for a master that
    // ignores the wait.
    input  wire        wr_en,
    input  wire [14:0] wr_addr,
    input  wire  [7:0] wr_data,
    output wire        wr_wait,

    // Drain read port. rd_req is a one-cycle strobe; rd_valid pulses once with rd_data.
    input  wire        rd_req,
    input  wire [14:0] rd_addr,
    output reg   [7:0] rd_data,
    output reg         rd_valid,

    // SDRAM port 2 (the controller's third requester): one 32-bit word per request.
    output reg         sdram_valid,
    input  wire        sdram_ready,
    output reg         sdram_write,
    output reg  [31:0] sdram_addr,
    output reg  [31:0] sdram_din,
    input  wire [31:0] sdram_dout,
    input  wire        sdram_resp_valid,
    output reg   [3:0] sdram_be,
    output wire  [7:0] sdram_burstcount
);

    // The controller's burst count is 4 bits at the port and 0 means ONE word; this module never
    // bursts, so it always asks for exactly one 32-bit word.
    assign sdram_burstcount = 8'd1;

    // ------------------------------------------------------------------
    // The write FIFO: {addr[14:0], data[7:0]} per entry, 4 deep, CIRCULAR (head + count).
    // A shift-down FIFO would make a same-cycle push and pop collide on one index; with a
    // head pointer the push index (head + count) and the pop's head advance never overlap.
    // ------------------------------------------------------------------
    localparam integer FW = 4;                    // FIFO depth (power of two)

    reg  [22:0] fifo [0:FW-1];                    // {wr_addr, wr_data}
    reg  [1:0]  fhead;                            // oldest entry
    reg  [2:0]  wcnt;                             // entries held

    wire        fifo_full  = (wcnt == 3'(FW));
    wire [22:0] fifo_head  = fifo[fhead];
    wire        fifo_empty = (wcnt == 3'd0);
    wire [1:0]  fifo_tail  = fhead + wcnt[1:0];

    // The push and the pop can land on the SAME cycle, and a separate `wcnt <= wcnt+1` in the
    // push would then be overwritten by the pop's `wcnt <= wcnt-1` (the later non-blocking
    // assignment wins), losing an entry's worth of count. So the count is computed ONCE, from
    // both events, and assigned in one place.
    wire        fifo_push = wr_en && !fifo_full;
    wire        fifo_pop  = (bstate == B_WR) && sdram_ready;
    wire [2:0]  wcnt_next = wcnt + (fifo_push ? 3'd1 : 3'd0) - (fifo_pop ? 3'd1 : 3'd0);
    assign      wr_wait = fifo_full;

    // ------------------------------------------------------------------
    // The request engine. One SDRAM access outstanding at a time.
    // ------------------------------------------------------------------
    localparam [1:0] B_IDLE  = 2'd0,   // choose the next request
                     B_WR    = 2'd1,   // a write is on the bus
                     B_RD    = 2'd2,   // a read is on the bus
                     B_RWAIT = 2'd3;   // waiting for the read's response

    reg  [1:0]  bstate;
    reg         rd_pending;                       // a latched read request
    reg  [14:0] rd_lat;                           // its address

    // Lane select for the read: which of the 32-bit word's four bytes to take. The write's
    // lane comes straight from fifo_head (the address the byte is stored with), so no
    // separate write latch is kept.
    wire [1:0] rd_lane = rd_lat[1:0];

    integer i;

    always @(posedge clk) begin
        if (reset) begin
            wcnt        <= 3'd0;
            bstate      <= B_IDLE;
            rd_pending  <= 1'b0;
            rd_lat      <= 15'd0;
            fhead       <= 2'd0;
            rd_data     <= 8'd0;
            rd_valid    <= 1'b0;
            sdram_valid <= 1'b0;
            sdram_write <= 1'b0;
            sdram_addr  <= 32'd0;
            sdram_din   <= 32'd0;
            sdram_be    <= 4'd0;
            for (i = 0; i < FW; i = i + 1) fifo[i] <= 23'd0;
        end else begin
            rd_valid <= 1'b0;

            // ---- the FIFO: push the guest's byte at the tail (the count is assigned below,
            // from both the push and the pop, so the two cannot race) ----
            if (fifo_push) begin
                fifo[fifo_tail] <= {wr_addr, wr_data};
            end
            wcnt <= wcnt_next;

            // ---- latch a read request ----
            if (rd_req && !rd_pending) begin
                rd_lat     <= rd_addr;
                rd_pending <= 1'b1;
            end

            // ---- the engine ----
            case (bstate)
                B_IDLE: begin
                    sdram_valid <= 1'b0;
                    if (!fifo_empty) begin
                        // Writes first: they are the guest's and cannot be made to wait. The
                        // address and byte ride on fifo_head, which is stable until the pop.
                        sdram_valid <= 1'b1;
                        sdram_write <= 1'b1;
                        sdram_addr  <= buf_base + {17'd0, fifo_head[22:8]};
                        // The byte's lane: replicated to all four so the byte-enable picks it.
                        sdram_din   <= {4{fifo_head[7:0]}};
                        sdram_be    <= 4'b0001 << fifo_head[9:8];   // addr[1:0]
                        bstate      <= B_WR;
                    end else if (rd_pending) begin
                        sdram_valid <= 1'b1;
                        sdram_write <= 1'b0;
                        sdram_addr  <= buf_base + {17'd0, rd_lat};
                        sdram_din   <= 32'd0;
                        sdram_be    <= 4'b1111;
                        bstate      <= B_RD;
                    end
                end

                B_WR: begin
                    if (sdram_ready) begin
                        sdram_valid <= 1'b0;
                        fhead  <= fhead + 2'd1;   // pop; wcnt is assigned above, from both events
                        bstate <= B_IDLE;
                    end
                end

                B_RD: begin
                    if (sdram_ready) begin
                        sdram_valid <= 1'b0;
                        bstate      <= B_RWAIT;
                    end
                end

                B_RWAIT: begin
                    if (sdram_resp_valid) begin
                        // The response is a 32-bit word; take the requested byte's lane.
                        rd_data    <= sdram_dout[{rd_lane, 3'b000} +: 8];
                        rd_valid   <= 1'b1;
                        rd_pending <= 1'b0;
                        bstate     <= B_IDLE;
                    end
                end

                default: bstate <= B_IDLE;
            endcase
        end
    end

    // A full FIFO is a STALL, not a drop: `wr_wait` back-pressures the guest's I/O
    // access through pc9821_iobus until the engine below has drained a slot. The
    // depth-4 sizing is no longer a correctness claim (the guest can write once per
    // ~10 clk_sys at IO_MIN_HOLD, faster than a contended SDRAM write); it is burst
    // absorption only, and the `!fifo_full` push guard survives solely for a master
    // that ignores `wr_wait`, where dropping still beats corrupting the FIFO.

endmodule

`default_nettype wire
