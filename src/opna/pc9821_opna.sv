// PC-9801-86 board glue around the vendored YM2608 (OPNA): one chip behind a two-address
// host port pair, banked by an A1 pin.
//   0x188 read chip status         | write register-select latch, low bank
//   0x18A read SSG/register shadow | write the selected register
//   0x18C read extended status     | write extended register-select
//   0x18E read extended data       | write extended data
// 0x18C/0x18E answer 0xFF until 0xA460 bit 0 enables the extension (NP2kai board86.c,
// pcm86io.c); 0x18A reads follow NP2kai's board shadow (opna_i18a), which master.lib's
// read-modify-write of SSG register 7 depends on (r12/06 P0-3). 0x188 is the chip's own
// status, so bit 7 is its BUSY and clears in bounded time (the games' WAITREADY, r12/06 P0-2).
// Clocking: the chip's 7.9872 MHz as a 32-bit DDS carry on clk (NP2kai OPNA_CLOCK doubled).
// Register writes are latched and presented to the chip at its own rate, because the vendored
// FM register file is a sample-rate operator scan that drops a write not held until its slot
// (the directly-latched SSG/ADPCM banks are immune).

`default_nettype none

module pc9821_opna #(
    parameter integer SYS_CLOCK_HZ = 50_000_000
) (
    input  wire        clk,
    input  wire        reset,        // synchronous, active high

    // Device bus, driven by pc9821_iobus. Only 0x0188/0x018A/0x018C/0x018E
    // are routed here (pc9821_system's opna_cs), so only addr[2:1] can vary:
    // pc9821_iobus decodes the rest of the 16-bit bus before it reaches this port.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [15:0] io_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire        io_wr,
    input  wire        io_rd,
    input  wire  [7:0] io_din,
    output reg   [7:0] io_dout,
    output wire        io_rd_wait,
    // Status-read hold: HIGH while a status read (0x188, or 0x18C with the extension open)
    // must wait for a queued flag-class write to reach the chip (flg_pend, below).
    // pc9821_iobus keeps the read in S_DEVWAIT while it is set (device_rd_hold) and
    // captures the byte on the cycle it drops. Low whenever no such write is queued, so
    // an idle queue keeps the one-cycle read.
    output wire        io_rd_hold,
    // Write back-pressure: asserted when the register-write queue cannot accept
    // a write this cycle. pc9821_iobus holds the guest's I/O access in its wait
    // state until this clears, so a no-polling write burst STALLS the CPU instead
    // of silently dropping writes past the queue (the drop boundary T9a measured:
    // 94 of 160 lost at the new IO_MIN_HOLD cadence). NP2kai applies every write;
    // stalling is the only faithful equivalent now that the chip's register file
    // is fed at its own scan rate.
    output wire        io_wr_wait,

    // 0xA460 bit 0: the -86's extension enable. Latched by pc9821_iobus.
    input  wire        extend,

    // The board's joystick read: register 0x0E returns these six switch lines, active low
    // -- up, down, left, right, button 1, button 2. They are the 9-pin connector's, so they
    // come from pc9821_gameport, which owns the connector (NP2kai sound/fmboard.c
    // fmboard_getjoy, reached from every one of its OPNA boards; cbus/board86.c:60-68).
    input  wire  [5:0] joystick,

    // Stereo output: the WIDE FM+ADPCM+SSG sum. `jtopna` delivers the FM+ADPCM
    // sum already clamped at its junction (jt08_acc restores ymfm's clamp16 on
    // the complete FM+ADPCM-A+ADPCM-B sum, ymfm_opn.cpp:1410-1414, then sign-
    // extends it to 20 bits) and leaves the SSG on a separate word; the two are
    // added here at the SSG level the upstream PC-88 board mix sets
    // (psg_snd << 2 - the measurement-derived board-trim correction is
    // DEFERRED per owner 2026-09-24; see the comment at the sum itself for the
    // measured range and the open owner question). The SSG is then
    // AC-COUPLED before the join: a 1-pole high-pass modelling the -86 board's
    // C7C1 series coupling capacitor,
    // which removes the SSG's unipolar DC so it joins the mix zero-mean. The
    // result is delivered in 20 bits (clamped FM+ADPCM [+-32,767] + zero-mean
    // SSG [+-6,138]). The SSG is added AFTER the FM clamp, exactly as ymfm adds
    // it after its clamp16. The LAST saturation of the whole -86 chain is the
    // FINAL DAC (z486_mister's mix_dry saturator, NP2kai's _saturation_s16),
    // which catches this tail.
    output wire signed [19:0] snd_l,
    output wire signed [19:0] snd_r,

    // Timer IRQ, active high, to the 8259's slave IR4 (system IRQ12, vector 0x14).
    output wire        irq,

    // Rhythm ROM pack-loader write port (pc9821_rhythm_loader -> jtopna ->
    // RHYTHM_ROM). With no user-supplied image the ROM reads as zeros, and that
    // is NOT silence: an all-zero ADPCM-A nibble is code 0 at step 0, a +2 delta
    // per sample, so every drum becomes a loud DC-carrying sawtooth (AGENTS.md
    // "Firmware pack (runtime inputs)"; tools/build_pack.py warns on a zero
    // region and tools/check_pack.py fails on one). See
    // src/opna/rhythm_rom/RHYTHM_ROM.v and the layout in tools/build_pack.py.
    input  wire        rhythm_we,
    input  wire [11:0] rhythm_waddr,
    input  wire [15:0] rhythm_wdata
);

  // ------------------------------------------------------------------
  // Clock enable: 7.9872 MHz on clk.
  // The numerator MUST be 64-bit: 2**32 * 7_987_200 overflows 32 bits, and the
  // truncation is the point of the accumulator. The quotient fits in 32 bits for
  // any SYS_CLOCK_HZ above 7.9872 MHz - it is 686_095_255 at 50 MHz - because
  // CEN_STEP = 2**32 * 7.9872e6 / SYS_CLOCK_HZ, so raising SYS_CLOCK_HZ lowers it.
  // ------------------------------------------------------------------
  /* verilator lint_off WIDTHEXPAND */
  /* verilator lint_off WIDTHTRUNC */
  localparam [31:0] CEN_STEP =
      (64'd4_294_967_296 * 64'd7_987_200) / (SYS_CLOCK_HZ + 64'd0);
  /* verilator lint_on WIDTHTRUNC */
  /* verilator lint_on WIDTHEXPAND */

  reg  [31:0] cen_acc;
  wire [32:0] cen_sum = {1'b0, cen_acc} + CEN_STEP;
  wire        cen     = cen_sum[32];

  always @(posedge clk) begin
    if (reset) cen_acc <= 32'd0;
    else       cen_acc <= cen_sum[31:0];
  end

  // ------------------------------------------------------------------
  // Reset: jt12 wants rst held for at least six clk&cen cycles
  // (jt12/hdl/jt08.v:23), so stretch it on the chip's own clock enable.
  // ------------------------------------------------------------------
  reg [4:0] rst_cnt;
  // op_rst is a REGISTER clocked by this same clk and stretched for 16 cen cycles, and jt12
  // consumes it as an asynchronous reset (`always @(posedge clk, posedge rst)`). That is safe
  // precisely because the source is a clean flop output: assertion AND deassertion are both
  // synchronous to clk, so there is no window in which the reset can be sampled mid-transition.
  // The warning fires because the same signal is used synchronously here and asynchronously
  // there - not because anything is unsynchronised.
  /* verilator lint_off SYNCASYNCNET */   // registered reset, synchronous release - see above
  reg       op_rst;
  /* verilator lint_on SYNCASYNCNET */

  always @(posedge clk) begin
    if (reset) begin
      rst_cnt <= 5'd16;
      op_rst  <= 1'b1;
    end else if (cen) begin
      if (rst_cnt != 5'd0) begin
        rst_cnt <= rst_cnt - 5'd1;
        op_rst  <= 1'b1;
      end else begin
        op_rst  <= 1'b0;
      end
    end
  end

  // ------------------------------------------------------------------
  // Register-write buffer. See the header: the vendored FM register file can
  // only absorb one operator write per operator scan, so host writes are
  // queued and handed to the chip one at a time, spaced by the chip's own
  // BUSY window. The directly-latched banks ride the same queue (their
  // register-select must still reach the chip before their data), which only
  // costs latency.
  // ------------------------------------------------------------------
  // The host port's own addressing: the card decodes 0x188..0x18F and uses
  // port bit 1 (CPU A1) as the chip's A0 and port bit 2 (CPU A2) as the
  // extension-bank select, so 0x188/0x18A are A0=0/1 of the base bank and
  // 0x18C/0x18E the same of the extended bank. Port bit 0 is the byte lane and
  // is always 0 at these four addresses (pc9821_iobus presents the odd byte of
  // a 16-bit access as its own port and leaves it open bus, as NP2kai does).
  wire [1:0] op_addr   = {io_addr[2], io_addr[1]};
  wire       op_ext    = io_addr[2];
  wire       op_sel    = !op_ext || extend;   // 0x18C/0x18E gated by 0xA460[0]

  // B-4: 0xA460 bit 0 dropping reconfigures the FM to 3-channel mono (NP2kai
  // extendchannel(0), cbus/board86.c:79-94). The matching drum key-off is the
  // queue injection declared beside the queue below.
  wire       ch3_mono  = ~extend;

  // 128 words = 64 select/data pairs. A polling guest sees BUSY only once this is half
  // full (wrq_busy, below), so the depth is what lets a burst run at the bus's own rate the
  // way the machine's does (it reads BUSY clear after every write), and the upper half is
  // what a guest that ignores BUSY fills before io_wr_wait stalls it. 128 x 12 is still
  // one M10K (its 512 x 20 shape).
  localparam integer WRQ_DEPTH = 128;  // power of two
  localparam integer WRQ_BITS  = 7;    // log2(WRQ_DEPTH)
  // The gap after a stretched chip write, in `cen` cycles: 36 clock enables = 216 cen,
  // 27.0 us. clk_en = cen/6 with the fixed 1/6 divider (jt12_div.v:60-62, mask_div=1).
  //   * The hold the register file needs is 25 enables (150 cen): it commits a pending
  //     operator write when its scan reaches the slot (jt12_reg.v
  //     `wire update_op_I  = cur == req_opch_I;`), the scan visits each of its 24 slots
  //     once per 24 clock enables, and the pending latches hold until the next data write
  //     replaces them (tb_pc9821_opna_wrq T2). A gap of exactly 25 leaves one enable of
  //     margin against that scan.
  //   * The chip's own write recovery is longer: the YM2608 is busy for 32 synthesizer
  //     cycles after a data write (ymfm ym2608::write_data
  //     `ymfm_set_busy_end(32 * m_fm.clock_prescale())`, 32 x 6 = 192 master clocks =
  //     24.04 us; the vendored jt12_mmr counts the same 32 enables, `busy lasts for 32
  //     synthesizer clock cycles`). 36 enables waits that out with 4 enables to spare, so
  //     a stretched write never reaches the chip inside the previous one's busy window
  //     (tb_pc9821_opna_flagsync T6). The guest does not wait for this gap: it is hidden
  //     behind the queue, so the 66 cen it adds over the bare scan cost only drain time.
  // Registers the chip latches on the bus write itself (SSG, ADPCM-A/B, timers, LFO,
  // the 0x1x selects) need only a couple of cycles.
  localparam integer DRAIN_GAP = 216;
  localparam integer SHORT_GAP = 2;

  // The queue storage is ONE 128x12 M10K, not three per-slot arrays (flip-flops
  // with one 12-bit write enable per slot, r13/113). A word is
  // {flagc, stretch, addr[1:0], data[7:0]} (flagc: is_flag_register below); one write
  // port and a registered read port make
  // it a simple dual port. no_rw_check is safe because the queue never reads the
  // slot it is writing: while it holds an entry the read pointer differs from the
  // write pointer, and at full it refuses writes (wrq_push is gated on wrq_cnt[WRQ_BITS]).
  (* ramstyle = "M10K, no_rw_check" *) reg [11:0] wrq_mem [0:WRQ_DEPTH-1];
  reg  [WRQ_BITS-1:0] wrq_wr, wrq_rd;
  reg  [WRQ_BITS:0]   wrq_cnt;
  wire                wrq_empty = (wrq_cnt == 0);

  // The register-select shadow the board model answers 0x18A from, and that
  // this buffer reads to tell an FM register (0x30-0xB6) from a directly
  // latched one. Declared here because the buffer uses it above its writer.
  reg [7:0] sel_lo;      // last value written to 0x188: the register select
  reg [7:0] sel_hi;      // last value written to 0x18C: the EXTENDED select (addrh)

  reg  [1:0]          dr_state;   // 0 = idle, 1 = present, 2 = wait
  reg  [7:0]          dr_gap;
  reg  [11:0]         dr_word;    // the block RAM's registered read output
  reg                 dr_fire;    // armed chip write (lands on the first host-free cycle)
  wire [1:0]          dr_addr = dr_word[9:8];
  wire [7:0]          dr_data = dr_word[7:0];
  wire                dr_str  = dr_word[10];
  wire                dr_flagc = dr_word[11];

  wire                host_wr  = io_wr && op_sel;
  wire                host_rd  = io_rd && op_sel;
  // S1: the chip write lands only on a host-free cycle. An armed dr_fire that
  // meets a host read's S_BYTE (or a host write) HOLDS instead - the host owns
  // the chip port that cycle (the addr/din muxes and wr_n are gated with dr_go
  // below) and the queued write retries the next cycle. Nothing is dropped and
  // jt12_dout can never latch the data-port case during a status read.
  wire                dr_go = dr_fire && !host_rd && !io_wr;

  // The one definition of which register the vendored FM register file can only
  // absorb at its own scan slot. Everything 0x30-0xB6 is the FM register file
  // (operator slots 0x30-0x9F through the sample-rate scan, channel slots
  // 0xA0-0xB6 through jt12_reg_ch, which also latches on the clock enable), on
  // either bank. 0x28 is not an operator slot, but it is the one register
  // jt12_mmr presents as a LEVEL - up_keyon, held until the next data write
  // (jt12_mmr.v:333-339) - and jt12_kon samples it only at the clock enable
  // (jt12_kon.v:70-78), so it needs the same hold to outlast the write behind
  // it. Only the BASE bank's 0x28 is key-on: jt12_mmr's REG_KON arm gates on
  // !part && !addr[1] (jt12_mmr.v:333).
  //   The base bank's rhythm key (0x10) and instrument levels (0x18-0x1D) need the same
  // hold. The rhythm unit keeps ONE pending key word, taken once per turn of its channel
  // counter (jt08_adpcm_drvA.v:79 `if( up_aon ) aon_cmd_cpy <= aon_cmd;`), and ONE pending
  // level word, which its gain ring copies into a drum's slot only when the ring reaches it
  // (jt08_adpcm_gain.v:83 `lracl2  <= up_ch_dec == cur_ch ? lracl : lracl1;`); a turn is
  // six 666 kHz enables, 9 us. A key or level write that lands sooner replaces the pending
  // one before its slot took it: that drum is never keyed, or keeps its old level and pan.
  // NP2kai (sound/rhythmc.c rhythm_setreg) and ymfm (ymfm_adpcm.cpp adpcm_a_engine::write)
  // apply every such write, and the YM2608 die takes 0x18-0x1D through the same pending FM
  // data word and slot match as the operator registers (YM2608-LLE fmopna_impl.c
  // `chip->rss_18 = chip->write_fm_data[0]`), so the drain gives them the FM write's gap.
  // MDRV2 3.4F writes 0x18-0x1D back to back at every song start; behind a queue that hides
  // BUSY, Touhou 1's title music lost its bass drum (tb_pc9821_opna_rhythm_level).
  function automatic is_fm_register(input [0:0] bank, input [7:0] sel);
    is_fm_register = ((sel >= 8'h30) && (sel <= 8'hB6)) ||
                     (!bank && (sel == 8'h28)) ||
                     (!bank && ((sel == 8'h10) || ((sel >= 8'h18) && (sel <= 8'h1D))));
  endfunction
  // Only a DATA write (A0=1, the chip's data port) is held: a register-select
  // write (A0=0) is latched by the chip on the bus write itself. The bank picks
  // which select latch the write used.
  wire                wrq_stretch = op_addr[0] &&
      is_fm_register(op_addr[1], op_addr[1] ? sel_hi : sel_lo);

  // THE FLAG CLASS: the queued data writes whose effect a status read (0x188, 0x18C) or
  // the IRQ line still reports when they drain. A status read behind one waits for it
  // (flg_pend below).
  //   Base bank 0x29: the IRQ enables, which gate the IRQ line for the ADPCM flags (not
  //   the timers: jt12_top.v's 0x29 LOCAL CHANGE, docs/probes/YM29-XE10.TXT).
  //   Extended bank 0x00 (ADPCM-B control 1: start, reset), 0x08 (the ADPCM-B memory
  //   data port, which clears BRDY on a CPU write: ymfm ymfm_adpcm.cpp
  //   adpcm_b_channel::write `m_status &= ~STATUS_BRDY;`) and 0x10 (flag control: the
  //   status masks, ymfm ymfm_opn.cpp read_status_hi `status &= ~(m_flag_control & 0x1f);`,
  //   and bit 7's ADPCM flag reset).
  //   Not 0x24-0x27: the flag resets and the timer registers act at the guest's write
  //   (host_clr_tmr, host_tmr below), and 0x27's queued CH3-mode bits touch no flag.
  function automatic is_flag_register(input [0:0] bank, input [7:0] sel);
    is_flag_register = bank ? ((sel == 8'h00) || (sel == 8'h08) || (sel == 8'h10))
                            : (sel == 8'h29);
  endfunction
  wire                wrq_flagc = op_addr[0] &&
      is_flag_register(op_addr[1], op_addr[1] ? sel_hi : sel_lo);
  // LOCAL CHANGE (B-4): NP2kai's extendchannel(0) keys off every rhythm drum by
  // writing rhythm register 0x10 = 0xff when 0xA460 bit 0 drops (cbus/board86.c:79-94).
  // That write is injected through the SAME queue as a host write - first the
  // register select (0x10), then the data (0xff) - so the chip sees the key-off
  // exactly as if software had written it. The board's sel_lo/last_data shadow is
  // deliberately left alone: NP2kai's rhythm_setreg writes the rhythm unit
  // directly, not the OPNA register shadow.
  reg         ext_prev;
  reg  [1:0]  ext_inj;       // 0 idle, 1 first word (select), 2 second word (data)
  wire        ext_drop      = ext_prev && !extend;
  wire        ext_inj_busy  = (ext_inj != 2'd0);
  // The injected pair must not be split by a host write landing between its two
  // words, so host writes wait (io_wr_wait below) and the injection yields to a
  // host write already presented rather than racing it.
  wire        inj_push      = ext_inj_busy && !wrq_cnt[WRQ_BITS] && !host_wr;
  wire  [1:0] inj_addr      = (ext_inj == 2'd1) ? 2'b00 : 2'b01;
  wire  [7:0] inj_data      = (ext_inj == 2'd1) ? 8'h10 : 8'hFF;
  wire        wrq_push      = host_wr && !wrq_cnt[WRQ_BITS] && !ext_inj_busy;
  wire        wrq_pop       = dr_go;   // the pop moves only when the fire completes
  wire        any_push      = wrq_push || inj_push;

  // THE TIMER FLAG RESET acts at the guest's bus write, not at the drain. The chip resets
  // a flag at the write (ymfm ymfm_fm.ipp engine_mode_write `set_reset_status(0, reset_mask);`
  // for 0x27 bits 4/5, ymfm_opn.cpp ym2608::write_data `m_fm.set_reset_status(0, 0xff);`
  // for 0x110 bit 7; NP2kai sound/opntimer.c opna_settimer
  // `opna->s.status &= ~((cData & 0x30) >> 4);`). Queued, the reset would land as late as
  // the drain ahead of it (up to 0.86 ms for a polling guest), and two things break:
  //   * PMD 4.8o's IRQ12 handler (PMD86.COM; PMD.COM and PMDB2.COM share it) reads 0x188
  //     through rdychk (`in al,dx` / `in al,dx` / `test al,al` / `js`, no timeout) in its
  //     INT_check loop (0x3A31), runs FM_Timer_main (0x3AA7) on a set flag, whose first
  //     write is 0x27 = 0x3F (reset BOTH flags, keep both timers loaded and enabled) and
  //     whose music tick follows, then reads 0x188 again and leaves only on a read of 0.
  //     A late reset makes that re-read find the flag still set: the tick runs twice.
  //   * the late reset also wipes an overflow the OTHER timer raised in between, which
  //     the guest then never services: a lost tick. 0x3F resets both flags whichever one
  //     the handler read, so the window is the whole drain, against a few instructions on
  //     the machine.
  // So the guest's reset reaches the chip's timers directly (host_clr_pls, a one-clk
  // pulse on the accepted write, through the vendored chip's flag-reset seam), and the
  // queued copy of 0x27 has bits 4/5 cleared; the queued 0x110 bit-7 write resets only
  // the ADPCM flags (the seam's jt12_mmr side), in order behind the ADPCM-B writes ahead
  // of it, which is why that part is not applied early: PMDB2's key-on writes the
  // ADPCM-B reset and start (0x100 = 0x21, 0xA0) and then 0x110 = 0x80 (PMDB2.COM 0x0722-
  // 0x0774), and an early ADPCM flag reset would leave the old sample's EOS to set again
  // before the restart lands. A reset pulse and a timer overflow in one clk resolve as
  // the vendored chip's own register-port reset does (jt12_timers: `if( clr_flag )`
  // before the set: the reset wins, the chip's rule for a write on the overflow cycle).
  wire                tmr_rst_27   = wrq_push && (op_addr == 2'b01) && (sel_lo == 8'h27);
  wire                all_rst_110  = wrq_push && (op_addr == 2'b11) && (sel_hi == 8'h10) &&
                                     io_din[7];
  wire [1:0]          host_clr_pls = ({2{tmr_rst_27}} & io_din[5:4]) | {2{all_rst_110}};

  // THE 0x110 TIMER-B MASK HOLDS THE FLAG CLEAR. On a real Xe10 with Timer B running and its
  // flag set, 0x110 <- 1F clears the flag at once and keeps it clear while the mask stands,
  // although the timer keeps overflowing; 0x110 <- 00 then brings it back only at the next
  // overflow (docs/probes/KIT1-XE10-OPNA.TXT STATUS3: `S3 A0 0110<-00 flag set 0188=0A
  // 018C=0A`, `S3 B0 0110<-1F 0188=08 018C=00`, `S3 B1 +100ms 0188=00 018C=00`, `S3 C0
  // 0110<-00 0188=00 018C=08`, `S3 C1 +100ms 0188=0A 018C=0A`; Timer B's period with
  // 0x26 = 00 is 256 x 288 us = 74 ms, inside the 100 ms between the B0 and B1 reads). The
  // references differ: ymfm only masks the 0x18C read (ymfm_opn.cpp ym2608::read_status_hi
  // `status &= ~(m_flag_control & 0x1f);`), qemu the same (fmopn.c ym2608_read
  // `& (F2608->flagmask|0x80)`), NP2kai has no mask, and the vendored jt12_mmr resets the
  // flag once at the write (`clr_flag_B  <= din[1];`), after which an overflow sets it again
  // (the core's run of the same probe: `S3 B1 +100ms 0188=02 018C=02`, docs/probes/core/
  // KIT1-CORE-rc-e6db0f05-s3-OPNA.TXT). So the glue latches bit 1 of a 0x110 write with bit 7
  // clear (bit 7 set is the flag reset, which leaves the mask: ymfm write_data_hi and
  // jt12_mmr alike) at the guest's write, as host_tmr is, and holds the chip's Timer B flag
  // reset through the flag-reset seam for as long as it stands. A held reset is a level, not
  // an event: jt12_timer's `if( clr_flag ) flag <= 1'b0;` keeps the flag at 0 and the line
  // that ORs it into the IRQ low. BIT 0 HOLDS TIMER A'S FLAG THE SAME WAY: kit 2 ran the rows
  // with Timer A running (NA = 0, 0x27 <- 15; docs/probes/KIT2-XE10-OPNA4.TXT:168-173 `S3A_A0
  // seen=1 st188=29 st18C=09`, `S3A_B0 ... st188=88 st18C=80` after 0x110 <- 1F, `S3A_B1 ...
  // st188=00 st18C=00` 100 ms later, `S3A_C0 ... st188=80 st18C=88` after 0x110 <- 00, `S3A_C1
  // ... st188=09 st18C=09`; Timer A's period with NA = 0 is 1024 x 72 / 7.9872 MHz = 9.2 ms),
  // where the one-shot reset let the flag back (the core's run, docs/probes/core/
  // KIT2-CORE-OPNA4.TXT `S3A_B1 seen=1 st188=01 st18C=01`).
  wire                flagctl_wr   = wrq_push && (op_addr == 2'b11) && (sel_hi == 8'h10) &&
                                     !io_din[7];
  reg                 tmr_mask_b;  // 0x110 bit 1 as last written with bit 7 clear
  reg                 tmr_mask_a;  // 0x110 bit 0 as last written with bit 7 clear
  always @(posedge clk) begin
    if (reset)           tmr_mask_b <= 1'b0;   // ymfm/jt12 reset: no flag masked
    else if (flagctl_wr) tmr_mask_b <= io_din[1];
  end
  always @(posedge clk) begin
    if (reset)           tmr_mask_a <= 1'b0;   // ymfm/jt12 reset: no flag masked
    else if (flagctl_wr) tmr_mask_a <= io_din[0];
  end
  wire [1:0]          host_clr_tmr = host_clr_pls | {tmr_mask_b, tmr_mask_a};

  // THE TIMER REGISTERS act at the guest's bus write too (owner, 2026-11-01, item 155 b).
  // 0x24 (NA bits 9-2), 0x25 (NA bits 1-0), 0x26 (NB) and 0x27 bits 3-0 (enable B, enable
  // A, load B, load A) are latched here on the accepted write and drive the chip's timers
  // through the same seam (host_tmr). The chip takes them at the write: ymfm
  // engine_mode_write `update_timer(0, m_regs.load_timer_a(), 0);` starts a timer at the
  // 0x27 write and NP2kai sound/opntimer.c:196 `if (!nevent_iswork(...))` the same; queued,
  // a start or a 0x26 tempo change behind a polling driver's FM stream would land up to
  // 64 words (0.86 ms) late.
  //   The timer itself is outside the operator scan (jt12_timers counts on timer_cen &&
  // zero and loads on the load bit's rising edge), so nothing audible reorders: the only
  // FM-side effects of 0x27 are bits 7-6, the CH3 mode (jt12_mmr `effect  <= |din[7:6];`,
  // `csm <= din[7:6] == 2'b10;`, which pick channel 3's per-operator F-numbers), and those
  // stay in the queued copy, behind the FM writes ahead of them. The queued 0x24-0x26
  // copies and 0x27's bits 3-0 still reach jt12_mmr's own timer latches, which the YM2608
  // configuration no longer reads (jt12_top takes host_tmr instead).
  //   A load written while the timer runs keeps the chip's rule: jt12_timer reloads its
  // count on the load bit's rising edge and otherwise only at an overflow, so a new NA/NB
  // takes effect at the next overflow and a 0x27 write that keeps load set does not restart
  // the count, as ymfm (`if (enable && !m_timer_running[tnum])`, reloaded from the
  // registers by engine_timer_expired `update_timer(tnum, 1, 0);`) and NP2kai
  // (set_fmtimeraevent re-reads 0x24/0x25 at each fmport_a) do.
  //   The decode follows tmr_rst_27: a data write to 0x18A applies to the base-bank select.
  wire                tmr_wr       = wrq_push && (op_addr == 2'b01);
  reg  [9:0]          tmr_na;
  reg  [7:0]          tmr_nb;
  reg  [3:0]          tmr_ctl;     // {enable B, enable A, load B, load A}
  always @(posedge clk) begin
    if (reset) begin
      tmr_na  <= 10'd0;
      tmr_nb  <= 8'd0;
      tmr_ctl <= 4'd0;
    end else if (tmr_wr) begin
      case (sel_lo)
        8'h24:   tmr_na[9:2] <= io_din;
        8'h25:   tmr_na[1:0] <= io_din[1:0];
        8'h26:   tmr_nb      <= io_din;
        8'h27:   tmr_ctl     <= io_din[3:0];
        default: ;
      endcase
    end
  end
  wire [21:0]         host_tmr     = {tmr_na, tmr_nb, tmr_ctl};
  wire [7:0]          wrq_din      = tmr_rst_27 ? (io_din & 8'hCF) : io_din;

  // The injected key-off is rhythm register 0x10, which no status read reports, so it is
  // never flag-class.
  wire [11:0] push_word     = inj_push ? {2'b00, inj_addr, inj_data}
                                        : {wrq_flagc, wrq_stretch, op_addr, wrq_din};
  // The queue-full back-pressure. `wrq_push` keeps its !full guard as the last
  // resort (a master that ignores io_wr_wait - a bare bench driving this module -
  // still loses the write rather than corrupting the queue), but the iobus never
  // presents such a write: it waits in S_IOWAIT while this is high. The same
  // wait also holds a host write while the two-word key-off injection is in
  // flight, so the pair is atomic with respect to the chip.
  assign                io_wr_wait = op_sel && (wrq_cnt[WRQ_BITS] || ext_inj_busy);

  // THE GUEST-VISIBLE BUSY (status bit 7 at 0x188 and 0x18C) is set while the queue is at
  // least half full (64 words) or the two-word key-off injection holds the port. With an
  // idle queue it is clear at once, which is what the machine shows: on the Xe10 the FIRST status read after every
  // write class - the address write, FM data 0x30/0x40/0xA0/0xB0, SSG 0x08, rhythm 0x11,
  // ADPCM-B 0x00 - finds BUSY clear (docs/probes/XE10T-XE10.TXT /OPNA, every T row
  // `polls=1/1/...`: min and median 1 poll of 32 trials), and that read completes about
  // 1.65 us after the data `out` starts. Neither the chip's own flag (jt12_mmr's 32
  // synthesizer-cycle busy, 192 cen = 24.0 us at 7.9872 MHz, which the guest saw as
  // 25.2 us after an SSG or rhythm write) nor this queue's drain (DRAIN_GAP, 27 us after
  // an FM data write) is therefore shown to the guest. jt12's busy is a status bit only:
  // nothing in the vendored chip gates a write on it, so masking it loses nothing. NP2kai
  // agrees with the common case: its 0x188 read returns the timer flags alone, with no
  // busy bit (cbus/board86.c opna_i188 `return g_opna[0].s.status;`).
  //   The capture's tail is NOT modelled. XE10T /OPNA2 (docs/probes/XE10T-XE10-OPNA2.TXT,
  // 128 write phases per class) finds every DATA write class busy at the first poll in
  // 18-27% of trials, then for 28-29 polls (28.5-30.1 us from the write, about 25 us of
  // BUSY): the YM2608's 32-cycle busy, 192 master clocks = 24.04 us (ymfm ymfm_opn.cpp
  // ym2608::write_data `ymfm_set_busy_end(32 * m_fm.clock_prescale())`); an address write
  // is never busy. The core reads clear at the first poll every time, which is faster;
  // whether to model the tail is item 155's owner question, and no guest can depend on
  // waiting, so the common case is the model.
  //   What the guest does not see is the queue's drain: a polling driver (PMD's rdychk,
  // master.lib's WAITREADY, MDRV2's busy mode all spin on bit 7 with no timeout) stacks
  // words at the bus's own rate and waits only once 64 are queued. That half-full point
  // bounds how far a polling driver's write can trail its `out`: at most 64 words ahead
  // of it, 32 FM data writes' gaps, about 0.86 ms. A guest that ignores BUSY fills the
  // other half and is then stalled by io_wr_wait, so no write is ever lost. The board's
  // read shadows (0x18A, 0x18E) answer from the write itself, so a read-back never sees
  // the lag; the flags are the one thing the chip reports that the lag can make stale,
  // and flg_pend below covers them.
  wire                wrq_half = wrq_cnt[WRQ_BITS] || wrq_cnt[WRQ_BITS-1];   // >= 64 words
  wire                wrq_busy = wrq_half || ext_inj_busy;

  // FLAG COHERENCE. A flag-class write (is_flag_register) acts on the chip at the bus
  // write; here it acts at its drain. A status read that the guest makes after it must
  // therefore not be answered until it has reached the chip, or the read reports a flag
  // the guest has already reset or masked. The guests read these (disassembled from the
  // shipped binaries; PMD's timer path is at host_clr_tmr above):
  //   * PMDB2 checks ADPCM-B EOS (0x18C bit 2) with a bare `in al,dx` / `test al,4`, no
  //     rdychk (PMDB2.COM 0x027E), after a key-on that wrote 0x110 = 0x80 (reset the
  //     flags) and 0x110 = 0x18 (0x076B); its ADPCM RAM transfers poll BRDY (bit 3) after
  //     each 0x108 byte, one loop with a 10000-read timeout (0x579C) and the others with
  //     none (0x57E5, 0x580A, 0x58A8).
  //   * MDRV2 3.4F (MDRV98.COM) reads 0x188 once at IRQ entry with no BUSY poll
  //     (0x18C7), writes 0x27 = 0x3F, runs its tick and leaves without a re-read; its
  //     ADPCM reads poll BRDY with no timeout (0x2026, 0x2092).
  // A BUSY bit would cover only the readers that poll it, so the guard is on the read: while a
  // flag-class write is queued, or has drained but its gap is still running, a status
  // read is HELD (io_rd_hold) and answered on the cycle the guard drops. The chip shows
  // the reset within 2 clk of the write (jt12_mmr latches clr_flag_* on the write,
  // jt12_timers clears flag on the next clk, jt12_dout registers it), well inside the
  // shortest gap that follows (SHORT_GAP, 2 cen). The hold is as long as the drain ahead
  // of the write: nothing with an idle queue (the machine's case), at most the 64 words
  // ahead of it for a polling guest, and at most a full queue's drain (64 FM data
  // writes, 1.7 ms) for a guest that ignores BUSY. Only a status read waits; a write
  // never waits for a flag-class write.
  //   flg_cnt counts the queued flag-class words: it rises at their push and falls at
  //   their pop. The two never meet in one cycle (a push is a host write and a pop needs
  //   a host-free cycle, dr_go), asserted below. flg_fly holds from a flag-class pop to
  //   the end of the gap that follows it.
  reg  [WRQ_BITS:0]   flg_cnt;
  reg                 flg_fly;
  wire                flg_push = wrq_push && wrq_flagc;
  wire                flg_pop  = wrq_pop && dr_flagc;
  wire                flg_pend = (flg_cnt != 0) || flg_fly;

  always @(posedge clk) begin
    if (reset) begin
      wrq_wr  <= {WRQ_BITS{1'b0}};
      wrq_rd  <= {WRQ_BITS{1'b0}};
      wrq_cnt <= {(WRQ_BITS + 1){1'b0}};
      dr_state <= 2'd0;
      dr_gap   <= 8'd0;
      dr_fire  <= 1'b0;
      ext_prev <= 1'b0;
      ext_inj  <= 2'd0;
      flg_cnt  <= {(WRQ_BITS + 1){1'b0}};
      flg_fly  <= 1'b0;
    end else begin
      // flg_push and flg_pop are exclusive (see flg_cnt), so each moves the count alone.
      flg_cnt <= flg_cnt + {{WRQ_BITS{1'b0}}, flg_push} - {{WRQ_BITS{1'b0}}, flg_pop};
      // Set by a flag-class pop (state 1), cleared when the gap after it ends (state 2):
      // the two arms are different drain states, so they never meet.
      flg_fly <= flg_pop ? 1'b1 :
                 ((dr_state == 2'd2) && cen && (dr_gap == 8'd0)) ? 1'b0 : flg_fly;
      if (any_push) wrq_wr <= wrq_wr + 1'b1;
      // LOCAL CHANGE (B-4): on a 0xA460 bit-0 drop, arm the two-word rhythm
      // key-off injection; it advances one word per queue push.
      ext_prev <= extend;
      case (ext_inj)
        2'd0: if (ext_drop) ext_inj <= 2'd1;
        2'd1: if (inj_push) ext_inj <= 2'd2;
        2'd2: if (inj_push) ext_inj <= 2'd0;
        default: ext_inj <= 2'd0;
      endcase
      case (dr_state)
        // The word is already in dr_word (the read port below registers it every
        // clk), so entering the present state needs no load of its own.
        2'd0: if (!wrq_empty && dr_gap == 8'd0)
                dr_state <= 2'd1;
        // The fire is armed one cycle ahead and RETRIES until its cycle is
        // host-free: a host read of 0x188 (the BUSY poll) or a host write
        // landing on the armed fire cycle owns the chip port (host priority),
        // so the fire holds - wrq_rd/wrq_pop do not move until the fire cycle
        // actually completes - and lands the next idle cycle instead of
        // corrupting the read (S1).
        2'd1: if (!dr_fire) begin
                if (!host_rd && !io_wr) dr_fire <= 1'b1;
              end else if (dr_go) begin
                dr_fire  <= 1'b0;
                wrq_rd   <= wrq_rd + 1'b1;
                dr_gap   <= dr_str ? DRAIN_GAP[7:0] : SHORT_GAP[7:0];
                dr_state <= 2'd2;
              end
        2'd2: if (cen) begin
                if (dr_gap == 8'd0) dr_state <= 2'd0;
                else                dr_gap <= dr_gap - 8'd1;
              end
        default: dr_state <= 2'd0;
      endcase
      wrq_cnt <= wrq_cnt + {WRQ_BITS{1'b0}} + any_push - {WRQ_BITS{1'b0}} - wrq_pop;
    end
  end

  // The write port, in its own block so the array infers as one M10K rather than a
  // flip-flop file (r13/110's split). wrq_wr is the write address register.
  always @(posedge clk)
    if (any_push) wrq_mem[wrq_wr] <= push_word;

  // The read port: the block's own registered output, so the drain's read stays one
  // clk deep exactly as the register array's dr_* load was. It reads every clk;
  // wrq_rd is stable unless the drain advances it, so the word it presents on the
  // idle-to-present edge is the one the register array would have latched there.
  always @(posedge clk)
    dr_word <= wrq_mem[wrq_rd];

  // ------------------------------------------------------------------
  // The chip's host port. A1 = io_addr[1] is the extended bank select, A0 =
  // io_addr[0] the address/data select, which is exactly `jtopna`'s addr[1:0].
  // A host write is one clk cycle (pc9821_iobus's S_BYTE strobe); a read is
  // answered one cycle later, which is why io_rd_wait is asserted and
  // pc9821_iobus takes its S_DEVWAIT cycle.
  // ------------------------------------------------------------------
  assign io_rd_wait = io_rd && op_sel;

  // The status-read hold (flg_pend, above). st_rd is the read strobe of a status port
  // (0x188, or 0x18C with the extension open: A0 = 0). rd_hold_q carries the read across
  // S_DEVWAIT (io_rd is a one-clk strobe) and falls the cycle after the hold does, before
  // any later read can strobe. The byte the iobus captures when the hold drops comes from
  // the chip's registered dout, which follows the chip's address of the cycle before; a
  // drain fire puts the queue's address there, but flg_pend only falls at the end of a
  // drain gap (flg_fly), a cycle with no fire before it, so the captured byte is always
  // the read's own (asserted below).
  wire       st_rd    = host_rd && !op_addr[0];
  reg        rd_hold_q;
  reg        dr_go_q;   // simulation check only: the cycle before the hold drops
  always @(posedge clk) begin
    if (reset) begin
      rd_hold_q <= 1'b0;
      dr_go_q   <= 1'b0;
    end else begin
      rd_hold_q <= st_rd || (rd_hold_q && flg_pend);
      dr_go_q   <= dr_go;
    end
  end
  assign io_rd_hold = rd_hold_q && flg_pend;

  // synthesis translate_off
  // SIM-ONLY (R8): the flag-class count's two events never meet, and it never underflows
  // or outgrows the queue.
  always @(posedge clk) begin
    if (!reset) begin
      if (flg_push && flg_pop)
        $fatal(1, "pc9821_opna: a flag-class push and pop in one cycle");
      if (flg_pop && (flg_cnt == 0))
        $fatal(1, "pc9821_opna: a flag-class pop with none queued");
      if (flg_cnt > wrq_cnt)
        $fatal(1, "pc9821_opna: more flag-class words than queued words");
      if (rd_hold_q && !flg_pend && dr_go_q)
        $fatal(1, "pc9821_opna: a held status read released right after a drain fire");
    end
  end
  // synthesis translate_on

  wire [7:0] op_dout;
  wire       op_irq_n;
  wire signed [19:0] fm_l, fm_r;
  wire [11:0] psg_snd;

  jtopna u_opna (
    .rst            (op_rst),
    .clk            (clk),
    .cen            (cen),
    // The chip only ever sees a chip write from the drain, and only ever sees
    // a read from a host read cycle (the same routing that keeps host writes
    // out of the chip while they sit in the buffer). Both muxes and wr_n are
    // gated with dr_go (S1): on a fire cycle the host claims, the chip sees the
    // host's own access alone and the write retries next cycle.
    .din            (dr_go ? dr_data : io_din),
    .addr           (dr_go ? dr_addr : op_addr),
    .cs_n           (~(host_rd | dr_go)),
    .wr_n           (~dr_go),
    .rd_n           (~host_rd),
    .dout           (op_dout),
    .irq_n          (op_irq_n),
    .IOA_in         (8'hFF),
    .IOB_in         (8'hFF),
    /* verilator lint_off PINCONNECTEMPTY */   // unwired on a PC-9801-86, see the notes here
    .IOA_out        (),
    .IOB_out        (),
    .IOA_oe         (),
    .IOB_oe         (),
    // No ADPCM-B sample RAM is wired yet: the chip reads zeros there, so
    // ADPCM-B is silent until that memory lands.
    .adpcm_addr     (),
    .adpcm_roe      (),
    .adpcm_din      (8'h00),
    .adpcm_wr       (),
    .adpcm_dout     (),
    /* verilator lint_on PINCONNECTEMPTY */
    .fm_snd_right   (fm_r),
    .fm_snd_left    (fm_l),
    .psg_snd        (psg_snd),
    .rhythm_we      (rhythm_we),
    .rhythm_waddr   (rhythm_waddr),
    .rhythm_wdata   (rhythm_wdata),
    .ch3_mono       (ch3_mono),
    .host_clr_tmr   (host_clr_tmr),
    .host_tmr       (host_tmr)
  );

  // ------------------------------------------------------------------
  // Port read model (NP2kai cbus/board86.c:55-76).
  // ------------------------------------------------------------------
  reg [7:0] last_data;   // last byte written through any data port: NP2kai's s.data

  // ------------------------------------------------------------------
  // The 16-byte SSG read shadow. It is ONE block RAM, not 128 flip-flops plus a
  // 16:1 read mux: one write port and one registered read is a simple dual port,
  // and a block memory holds it for no logic ALMs at all -- where the flop array
  // costs 2.00 registers per ALM (res-mlab-REPORT: 256 flops = exactly 128 ALMs)
  // on top of the mux -- while block RAM is the resource this design does NOT
  // bind on. Registers -> block RAM is the profitable direction, and M10K is the
  // right end of it: an MLAB IS a LAB, so parking the array there would spend the
  // BINDING resource to buy back the free one (res-mlab-REPORT section 0).
  //
  // THE READ IS REGISTERED, one clk behind sel_lo, and that is free at this
  // port: sel_lo moves on its OWN 0x188/0x18C bus access, never on the 0x18A
  // read that answers from it, and that read is already a waited one
  // (io_rd_wait) whose byte is captured a cycle after the strobe.
  //
  // THE TWO THINGS THAT WOULD SILENTLY BLOCK THE INFERENCE ARE ABSENT BY
  // CONSTRUCTION (the kbd_lut trap, res-mlab-REPORT section 7.2): the array
  // carries NO reset -- a reset blocks inference exactly as a power-up value on
  // its read register does -- and ssg_rd_q carries no power-up value. A memory's
  // power-up contents are therefore the board's reset values, and a LATER reset
  // is put back through the array's own port by ssg_seed below.
  //
  // no_rw_check: the guest's 0x18A write can land on the address the read port
  // presents that cycle, and what the read returns then is don't-care -- ssg_rd_q
  // samples it and refreshes on the next clk, long before any access answers
  // from it (wrq_mem declares the same thing for the same reason).
  // ------------------------------------------------------------------
  (* ramstyle = "M10K, no_rw_check" *) reg [7:0] ssg_reg [0:15];

  integer i;

  // The array's POWER-UP contents are the board's reset values, because a memory
  // cannot be reset (see above). NP2kai opna_reset seeds three of the SSG shadow
  // bytes (sound/opna.c:135-140):
  // reg[7] = 0xbf, reg[14] = 0xff, reg[15] = 0xff. THE MACHINE REFUTES THE
  // reg[7] SEED. Probe OPNAPRO selects SSG register 7 and reads 0x00
  // (docs/probes/OPNA.TXT section CHIPID, `0x18A with 0x188=07 (SSG register 7;
  // the references' reset seed is BF): 00`) on a card the same block proves
  // present (0x188 = FF answers the -86 chip ID 0x01), so the byte is the
  // chip's and not open bus; both software models answer 0xbf and are wrong.
  // The die-shot LLE is with the machine: an SSG read returns the register
  // itself (fmopna_impl.c:2232-2235) and reset loads it from an internal bus
  // that is 0 (:2114-2130). ymfm's SSG resets all-zero as well
  // (ymfm_ssg.cpp:44-47 with ssg_engine::reset :86-93).
  // r12/06 section 2.1c argued the other way: master.lib's js_start
  // (rec98 libs/master.lib/js_start.asm:67-72, read reg 7 / and 3Fh / or 80h /
  // write back) turns a 0x00 read into 0x80 - every SSG tone and noise source
  // ROUTED - and that was read as corruption. The capture shows 0x80 is the
  // hardware's own outcome, and it is what makes js_start mean "start the
  // SSG": from a 0xbf read the write-back is 0xbf, i.e. all six sources
  // DISCONNECTED and an SSG that stays silent however the guest programs its
  // periods and amplitudes.
  // SCOPE: this is the BOARD's read shadow, the read the guest sees. The
  // CHIP's own copy of the register (the vendored jt49 regarray[7], a LOCAL
  // PATCH at src/opna/jt49/hdl/jt49.v:240) still powers up 0xBF, so shadow and
  // chip disagree until the guest writes reg 7; that is an AUDIO-side decision
  // with its own bench (tb_pc9821_opna_ssg_powon) and is deliberately NOT
  // changed with this read-back fix.
  // Register 0x0E is SHADOW-ONLY here - 0x18A answers it from the joystick
  // (opna_i18a, above), so this byte can never be read back - but NP2kai holds
  // 0xFF there and an exact shadow is the point of this block (opna-audit F7).
  initial begin
    for (i = 0; i < 16; i = i + 1) ssg_reg[i] = 8'h00;   // incl. reg 7: the machine's 0x00
    ssg_reg[14] = 8'hFF;
    ssg_reg[15] = 8'hFF;
  end

  reg [7:0] ssg_rd_q;
  // BYTE-IDENTICAL TO THE FORM THAT INFERS. The array's one read port stays exactly
  // `ssg_rd_q <= ssg_reg[sel_lo[3:0]]`, with no reset and no power-up value on the register
  // (a reset here, or an initial value there, is what silently puts a table back in LUTs -
  // the RAM-inference trap). Everything the reset fix needs lives on the READ MUX in
  // io_dout and on the write port below, not on this line.
  always @(posedge clk) ssg_rd_q <= ssg_reg[sel_lo[3:0]];

  // The reset a memory cannot take, written back through its OWN port: one entry per clk for
  // the 16 clk AFTER the reset lifts (during the reset the counter holds 0 and re-writes entry
  // 0 with the same 0x00).
  //
  // THE SWEEP IS THE RESET, AND IT IS ATOMIC FROM THE GUEST'S SIDE BY CONSTRUCTION
  // (v-reset-audit F1/F2). A bare 16-clk sweep has NEITHER of the two facts below; both are
  // module state, and neither is a margin against the CPU reset gate's hold:
  //   * ssg_ok[a] means entry a's array word is THIS epoch's byte - the sweep has reached it,
  //     or the guest wrote it since this reset. A read of an entry that is neither answers the
  //     reset image (ssg_reset_byte) instead of the array, so the FIRST 0x18A read after a
  //     reset can never see a pre-reset byte. F1: a read of register 0x0F right after a reset
  //     answered the pre-reset 0x80 while the flop form installed 0xFF.
  //   * the sweep does not touch an entry the guest has written (ssg_ok set by the write path),
  //     so a byte the guest writes is never clobbered by it. F2: a write of reg 0x0A four clk
  //     into the sweep read back the reset 0x00 - same-cycle write priority saved only the
  //     write's own cycle, and the sweep still visited entry 10 later.
  // So a guest write arriving inside the window STICKS (it is not deferred and not lost), and
  // the read side answers the INTENDED post-reset value for the entries the sweep has not
  // reached. Nothing here depends on the ~1-clk margin between the 16-clk sweep and the CPU
  // reset gate's 15-cycle hold, which the audit found nothing pinning.
  //
  // THE REJECTED ALTERNATIVE, recorded because it is the obvious first idea: hold the guest off
  // the device until the sweep finishes (drive io_wr_wait / a read-hold from the sweep's done
  // signal). That fixes F1 and leaves F2 intact - it only DEFERS a write, and the module still
  // clobbers one presented inside the window, so F2's own minimal case (a direct 0x18A write
  // four clk into the sweep) still reads back 0x00 across cycles. Satisfying both findings at
  // the module boundary, for a bare master as well as through pc9821_iobus, is strictly better
  // than pinning an integration margin. The cost of this form is ssg_ok's 16 flops; the
  // 16-entry array and its inference are untouched.
  function automatic [7:0] ssg_reset_byte(input [3:0] ad);
    ssg_reset_byte = (ad >= 4'hE) ? 8'hFF : 8'h00;   // entries 14 and 15 carry 0xFF
  endfunction

  reg  [4:0] ssg_seed;                       // 0..15 = the entry being restored; 16+ = done
  reg [15:0] ssg_ok;                         // entry's array word is this epoch's byte
  wire       ssg_seed_we = (ssg_seed < 5'd16);
  wire [3:0] ssg_seed_ad = ssg_seed[3:0];
  wire [7:0] ssg_seed_da = ssg_reset_byte(ssg_seed_ad);
  // The guest's shadow write: 0x18A is the data port and only sel_lo < 0x10 names one of the
  // sixteen shadow entries (0x18A answers everything at or above 0x10 from last_data).
  wire       ssg_guest_we = !reset && io_wr && op_sel && (op_addr == 2'b01) &&
                            (sel_lo < 8'h10);

  always @(posedge clk) begin
    if (reset) begin
      ssg_seed <= 5'd0;
      ssg_ok   <= 16'd0;
    end else begin
      // The sweep visits every entry and skips the ones the guest already wrote; a
      // same-cycle collision leaves that entry's stale word in the array with ssg_ok
      // still low, so the read mux answers the reset image for it and the stale word is
      // never observable (and a later guest write to it sets ssg_ok and is read back).
      if (ssg_seed_we) ssg_seed <= ssg_seed + 5'd1;
      if (ssg_guest_we)
        ssg_ok[sel_lo[3:0]] <= 1'b1;
      else if (ssg_seed_we && !ssg_ok[ssg_seed_ad])
        ssg_ok[ssg_seed_ad] <= 1'b1;
    end
  end

  // The shadow's write port, in its own block so the array reads as a plain
  // simple dual port (wrq_mem's write port is split out the same way). The guest keeps
  // priority on the cycle it collides, and the sweep skips an entry it must not clobber.
  always @(posedge clk) begin
    if (ssg_guest_we)
      ssg_reg[sel_lo[3:0]] <= io_din;
    else if (ssg_seed_we && !ssg_ok[ssg_seed_ad])
      ssg_reg[ssg_seed_ad] <= ssg_seed_da;
  end

  always @(posedge clk) begin
    if (reset) begin
      sel_lo    <= 8'h00;
      sel_hi    <= 8'h00;
      last_data <= 8'h00;
    end else begin
      // 0x188 sets the low-bank register latch AND the data shadow.
      // NP2kai's opna_o188 (cbus/board86.c:14-19) assigns BOTH s.addrl and
      // s.data, and opna_i18a returns s.data for every low address that is not
      // 0x0E, 0xFF or below 0x10. So a 0x188 write alone must make a following
      // 0x18A read answer the byte just written; with the shadow untouched it
      // would answer whatever the last 0x18A write put there instead.
      if (io_wr && op_sel && (op_addr == 2'b00)) begin
        sel_lo    <= io_din;
        last_data <= io_din;
      end
      // 0x18C is the extended bank's register latch. It is reached only when
      // the extension is on -- pc9821_iobus and `op_sel` above already gate
      // that, matching NP2kai's opna_o18c, which guards on s.extend. Like
      // opna_o188 it also moves the data shadow a 0x18E read answers from
      // (opna_o18c: s.addrh = dat; s.data = dat;) -- without that, a 0x18C
      // write followed by a 0x18E read answers the previous 0x18A/0x18E byte
      // instead of the select byte just written.
      if (io_wr && op_sel && (op_addr == 2'b10)) begin
        sel_hi    <= io_din;
        last_data <= io_din;
      end
      // 0x18A writes the byte into the chip and into the shadow the read
      // answers from (the shadow's own write port is beside its declaration).
      if (io_wr && op_sel && (op_addr == 2'b01))
        last_data <= io_din;
      // 0x18E is the extended bank's data byte, and NP2kai's opna_o18e
      // (cbus/board86.c:92-110) only reads the CHIP for addrh 0x08 and 0x0F;
      // every other extended address returns s.data. Answering the chip for all
      // of them is a wider read than the board gives.
      if (io_wr && op_sel && (op_addr == 2'b11))
        last_data <= io_din;
    end
  end

  // The base-bank selects that read FF through 0x18A while 0xA460 bit 0 holds the extension
  // closed (the read map below, docs/probes/KIT1-XE10-YM29.TXT READMAP).
  // Kit 2 read every select (docs/probes/KIT2-XE10-OPNA4.TXT:126-142, RMAP_C): 0x30-0xFE echo
  // the select except 0xB4-0xB7, which read FF (`RMAP_C rB0=B0B1B2B3FFFFFFFFB8B9BABBBCBDBEBF`).
  function automatic reads_ff_closed(input [7:0] sel);
    reads_ff_closed = (sel[7:4] == 4'h1) || (sel == 8'h22) || (sel == 8'h29) ||
                      (sel[7:2] == 6'b1011_01);
  endfunction

  always @* begin
    case (op_addr)
      // Chip status: the chip's flags with BUSY replaced by the queue's back-pressure
      // (wrq_busy, see its declaration: the machine reads BUSY clear at the first poll).
      2'b00: io_dout = {wrq_busy, op_dout[6:0]};    // chip status
      // The board's joystick register, register 0x0E: the connector's six switch lines,
      // active low (NP2kai fmboard_getjoy, which returns its result masked to 0x3F). The
      // two upper bits stay 1: NP2kai ORs the chip's own interrupt flags into them
      // (sound/fmboard.c:92-93), and the machine's measured idle byte is 0xFF (probes/JOY.TXT),
      // so only the six switch lines are this register's live part.
      // Register 0x10 (the rhythm dump/key) reads 0xFF while 0xA460 bit 0 holds the
      // extension closed: the Xe10 reads FF there with the extension closed and the select
      // echo 10 once it is open, while 0x20 echoes 20 both ways (docs/probes/
      // XE10T-XE10-OPNA2.TXT `X IDC b=0188 ext=0 ... r10=FF r20=20`, `ext=1 ... r10=10`).
      // NP2kai answers s.data (the echo) either way. With the extension closed, the kit-1
      // read map widens it: every rhythm register 0x10-0x1F, 0x22 (LFO) and 0x29 (the IRQ
      // enable) read FF, 0x20-0x2F otherwise echo the select (docs/probes/KIT1-XE10-YM29.TXT
      // `READMAP b=0188 r00= ... r10= FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF r20= 20
      // 21 FF 23 24 25 26 27 28 FF 2A`, with `BASE b=0188 ... a460=40`: bit 0 closed), and
      // 0x29 reads FF before and after each write of 1F, 03, 02, 01 and 00 (`RD29 v29=1F
      // pre=FF post=FF` ... `RD29 v29=00 pre=FF post=FF`). ymfm and qemu answer 00 for every
      // register but 0x00-0x0F and 0xFF (ymfm_opn.cpp ym2608::read_data, qemu fmopn.c
      // ym2608_read `case 1:`), NP2kai s.data (cbus/board86.c opna_i18a): the machine rules.
      // Kit 2's full sweep (docs/probes/KIT2-XE10-OPNA4.TXT:126-159) adds 0xB4-0xB7 (FF while
      // closed, `RMAP_C rB0=B0B1B2B3FFFFFFFFB8B9`) and shows the rest of 0x30-0xFE echo the
      // select both ways, and every select 0x10-0xFE echo it with the extension open
      // (`RMAP_O r10=101112131415161718191A1B1C1D1E1F`, `RMAP_O rB0=B0B1B2B3B4B5B6B7B8B9`).
      2'b01: io_dout = (sel_lo == 8'h0E) ? {2'b11, joystick} :
                       (sel_lo == 8'hFF) ? 8'h01 :    // the -86 chip ID
                       (!extend && reads_ff_closed(sel_lo)) ? 8'hFF :
                       // The shadow read, through the sweep above: an entry this epoch's
                       // sweep has not restored (and the guest has not written) still holds
                       // its PRE-reset byte in the array, so the read answers the reset
                       // image instead. ssg_rd_q is the array's own plain registered read.
                       (sel_lo < 8'h10)  ? (ssg_ok[sel_lo[3:0]] ? ssg_rd_q
                                                                 : ssg_reset_byte(sel_lo[3:0]))
                                         : last_data;
      // Extended status. Bit 7 is the chip's BUSY (jt12_dout 2'b10: {busy, 0,
      // adpcmb_flag2, flag_B, flag_A}), replaced exactly as at 0x188 (the capture's
      // BUSY_ADPCMB00 row polls 0x188 after a 0x18C/0x18E write: polls=1/1/1).
      2'b10: io_dout = extend ? {wrq_busy, op_dout[6:0]} : 8'hFF;   // extended status
      // Extended data: the chip answers only for addrh 0x08 and 0x0F; every
      // other extended register reads back the data shadow (NP2kai opna_o18e).
      default: io_dout = extend ? ((sel_hi == 8'h08 || sel_hi == 8'h0F) ? op_dout
                                                                       : last_data)
                                : 8'hFF;
    endcase
  end

  // ------------------------------------------------------------------
  // Output: the clamped FM+ADPCM junction + the AC-coupled (zero-mean) SSG,
  // carried in 20 bits. The FM+ADPCM sum was already clamped to 16 bits at the
  // jt08_acc junction (ymfm's clamp16, ymfm_opn.cpp:1407-1413); the SSG joins
  // here, after that clamp, and the chain's LAST saturation is the final DAC
  // (z486_mister's mix_dry).
  //
  // THE JOIN IS psg * 33/16 = the upstream PC-88 board-mix BASELINE (psg << 2)
  // times the -86 board's SSG:FM summing ratio, MEASURED from the owner's
  // paired SNDTEST captures.
  //   * baseline = psg << 2: upstream PC-88's heard board mix joins the SSG at
  //     `psg_snd => sndPSG(13 downto 2)` (PC88MiSTer.vhd:2505, joined at
  //     :2509-2513) and qemu's closed ratio SSG_ch:FM_op = 8,160:8,192 = 1.0
  //     (pc98-opna.c:372 `PSG_calc(s->ssg) << 1` over emu2149's
  //     voltbl[vol] << 4) puts one max SSG channel at 1,023 << 2 = 4,092 in our
  //     junction units (jt49_exp's LUT peaks at 1,023), where our chip-side
  //     junction runs at HALF qemu's absolute scale - the FM operator is
  //     +/-4,096 (jt08_acc `opext >>> 1`; qemu's `lt >>= 1 ... // shift right
  //     verified on real YM2608`, hw/audio/fmopn.c:3023-3025) and a full drum
  //     is +/-15,352 (((2047<<4)*15)>>5 & ~3; jt08_adpcm_gain = ymfm
  //     adpcm_a_channel::output, ymfm_adpcm.cpp:223-243), where qemu's
  //     junction carries 8,192 and 30,720 (fmopn.c init_tables "13 bits
  //     here"; :2689 + out_adpcm<<1).
  //   * the -86 board trim, MEASURED (the die stops at its pins: the SSG is
  //     `o_analog`, a separate mono ANALOG pin, fmopna_impl.c:2438-2441, while
  //     FM+ADPCM leave as the YM3016 DAC word - so the ratio between the two
  //     paths is the BOARD's analog summing network and is in NO chip model).
  //     The owner ran SNDTEST (the same register stimulus) on the real Xe10 twice and on this core once, with
  //     un-normalised line-out recordings; the WITHIN-SIDE ratio
  //     SSG(max)/FM(max) is immune to the two recorders' unrelated gains. It is
  //     measured on each segment's own STEADY-STATE plateau by class (SEG 07's
  //     440 Hz square against SEG 01's 440 Hz sine; the plateau reader and the
  //     pairing are tools/sndtest_balance.py, output in
  //     docs/probes/SNDTEST-balance-2026-09-25.txt):
  //       XE10 + PMD -8.79 dB   XE10 no PMD -8.79 dB   this core -3.03 dB
  //     and the INDEPENDENT second pairing (the SSWP 100 Hz row against the
  //     FSWP 100 Hz row, both nominal 0 dB) agrees to 0.05 dB on every file
  //     (-8.75, -8.74, -2.99). The machine reproduced itself to 0.01 dB across
  //     the two sessions, so 5.76 dB of SSG leg is hot and the FM leg is taken
  //     as right - which is also the physically sensible direction (the board's
  //     summing network attenuates the SSG against the FM).
  //     psg_snd * 33/16 = 2.0625 is -5.756 dB off the psg << 2 baseline, i.e.
  //     it lands this core at -8.77 dB against the machine's -8.79 (0.02 dB),
  //     where the nearest single-shift constant (psg << 1, -6.02 dB) lands at
  //     -9.03 and misses by 0.26 dB - real, not noise, at a repeatability of
  //     0.01-0.05 dB. Verified against the module before landing:
  //     tb_pc9821_opna_sndtest_balance measures -2.99 dB with the old join,
  //     i.e. the capture and the RTL agree to 0.04 dB on this side.
  //     The analog capture chain cannot have distorted this ratio materially:
  //     the machine's own SSG sweep is flat within 0.35 dB from 100 Hz to 4 kHz
  //     and its FM sweep within 0.1 dB to 2 kHz (the chains' own response was
  //     measured too), the SSG square's
  //     harmonics are intact on the machine (its 3rd is -9.5 dB, the ideal
  //     -9.54), and the FM at 440 Hz is a sine whose power is below 1 kHz.
  //     tb_pc9821_opna_sndtest_balance is the fail-first for this number, with
  //     the expected ratio taken from the capture rows above.
  //   * the drum/FM side is unchanged and die-exact (drum-hit/bed matches the
  //     machine to 0.0 +/- 0.3 dB paired; the die's gain laws are 0-mismatch
  //     against YM2608-LLE).
  //   * the owner's re-ranking is recorded: for the FM/SSG BALANCE the upstream
  //     PC-88 Verilog is the baseline OVER NP2kai's absolute SSG gain (a
  //     software mix knob) - and the real machine outranks both for the board
  //     trim ("when the real hardware says something different from both, the
  //     hardware wins"). ymfm's s_amplitudes[31] = 16,382/ch (its MixTo1 2/3
  //     mix puts a max channel at 0.333 of its clamp rail, 6.4-7.5 dB above
  //     the machine's ~0.14-0.16, 20*log10(0.333/0.14..0.16)) and NP2kai's vol_ssg absolutes are
  //     deliberately unused. The A-11 `<< 3` history is why both the
  //     baseline and the correction are stated separately above: the units
  //     question (qemu-full vs our half-scale junction) and the board-trim
  //     question (recordings) are different errors and only the latter is
  //     addressed here.
  // The -86 board AC-COUPLES the SSG before it is summed into the YM3016 FM/DAC
  // output: the SSG leaves pin 27 with a ~2 V DC offset (a YM2149-style unipolar
  // output, which jt49 models), passes the series coupling capacitor C7C1, and
  // only then is summed equally into L/R.
  // A series cap is a 1-pole high-pass:
  //   y[n] = x[n] - x[n-1] + a*y[n-1],  a = 1 - 2^-N
  // clocked on the SSG's own sample rate. The SSG sample word (jt49's `sound`,
  // jt49.v:174-193) updates once every 4 clk_en_ssg pulses; jt12_div divides cen
  // by 4 for the SSG at the YM2608 reset setting (jt12_div.v:60-99), so that is
  // once every 16 cen = 7.9872 MHz / 16 = 499.2 kHz. N=14 puts the cutoff at
  // fc = fs*2^-N/2pi ~= 4.85 Hz - coupling-cap-like and well below 20 Hz (the
  // exact -86 cap value is not published; see the lane FIX_REPORT).
  //
  // The filter runs on the JOIN-SCALE integer, not the raw 12-bit psg_snd: one
  // max channel (jt49_exp's LUT peak 1,023) is then a 0..2,109 square wave the
  // mix carries (three channels: 0..6,329), which is what the AC coupling has
  // to centre. The join's floor is <=15/16 LSB on values that are not multiples
  // of 16 - at most -62 dB relative to a max channel - and the coupling removes
  // whatever DC is left either way. The
  // accumulator keeps SSG_DC_F=16 fractional bits so
  // the a=1-2^-N leak term is never truncated to zero (the DC-blocker precision
  // trap): the DC component scaled by 2^F is far above 2^N, so (state >>> N) is
  // non-zero and the DC is actually removed, not merely shrunk. The state is a
  // continuous DSP register clocked by a clock-enable (ssg_cen), which the
  // Single-Cycle Event Discipline permits; ssg_cen is a 1-clk pulse with exactly
  // one consumer (this filter).
  localparam integer SSG_DC_N = 14;   // a = 1 - 2^-14; fc ~= 4.85 Hz at 499.2 kHz
  localparam integer SSG_DC_F = 16;   // accumulator fractional bits (2^-16 per LSB)

  reg  [3:0]         ssg_div;         // cen / 16 = the SSG sample rate (499.2 kHz)
  reg  signed [17:0] ssg_x_prev;      // previous join-scale SSG sample (psg * 33/16)
  reg  signed [31:0] ssg_hp_state;    // 1-pole high-pass state, 16 fractional bits
  wire               ssg_cen = cen & (ssg_div == 4'd15);
  // THE JOIN UNIT (the big comment above): psg_snd * 33/16 - the psg << 2
  // baseline times the MEASURED board trim 33/64. The multiply is 12x6 bits;
  // the three-channel maximum 3,069 joins at 6,329, inside the 18-bit signed
  // path (131,071) with ssg_d likewise bounded.
  localparam [5:0]   SSG_JOIN_NUM   = 6'd33; // join = psg_snd * SSG_JOIN_NUM / 16
  localparam integer SSG_JOIN_SHIFT = 4;
  wire [17:0]        ssg_prod = psg_snd * SSG_JOIN_NUM;       // 0..135,135
  wire signed [17:0] ssg_x    = ssg_prod >> SSG_JOIN_SHIFT;   // >>4 -> 0..8,445
  wire signed [17:0] ssg_d    = ssg_x - ssg_x_prev;           // ±8,445, fits 18-bit signed
  wire signed [31:0] ssg_dw   = $signed({{14{ssg_d[17]}}, ssg_d});  // sign-extend to the accumulator width
  // The AC-coupled (zero-mean) SSG term at the mix join, sign-extended to 20 bits.
  wire signed [19:0] ssg_ac  = { {4{ssg_hp_state[31]}}, ssg_hp_state[31:16] };

  always @(posedge clk) begin
    if (reset) begin
      ssg_div      <= 4'd0;
      ssg_x_prev   <= 18'sd0;
      ssg_hp_state <= 32'sd0;
    end else begin
      if (cen) ssg_div <= ssg_div + 4'd1;
      if (ssg_cen) begin
        ssg_x_prev   <= ssg_x;
        ssg_hp_state <= (ssg_dw <<< SSG_DC_F) + ssg_hp_state - (ssg_hp_state >>> SSG_DC_N);
      end
    end
  end

  wire signed [19:0] mix_l = fm_l + ssg_ac;
  wire signed [19:0] mix_r = fm_r + ssg_ac;

  assign snd_l = mix_l;
  assign snd_r = mix_r;

  assign irq = ~op_irq_n;

endmodule

`default_nettype wire
