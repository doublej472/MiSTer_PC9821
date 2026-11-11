// The NEC PC-98 "bus mouse": a uPD8255 PPI at 0x7FD9-0x7FDF wired to a
// quadrature mouse with three buttons and a periodic interrupt on IRQ13 (slave
// IR5). NP2kai io/mouseif.c is the primary reference for every protocol value
// here; qemu-pc98 hw/input/pc98-mouse.c and MAME src/mame/nec/pc9801.cpp
// (evidence tiers 4 and 5) agree with it on every point this module pins and
// are cited only where they add detail NP2kai leaves implicit.
//
// The 8255 register file (NP2kai mouseif_o7fd9/o7fdb/o7fdd/o7fdf and
// mouseif_i7fd9/i7fdb/i7fdd, io/mouseif.c:179-307; direction bits uPD8255_*
// in io/lsidef.h:9-17):
//
//   0x7FD9  Port A  write: porta latch; read (A = input): buttons in the upper
//           nibble with one X/Y counter nibble in the lower; read (A = output):
//           the porta latch. Port C bits 7:5 steer the nibble:
//             bit 7 (HC)  1 = the LATCHED counters, 0 = the live ones, and a
//                         0->1 edge on it latches x/y (clamped to signed 8
//                         bits) and clears them (mouseif.c:144-163)
//             bit 6 (SXY) 1 = the Y counter in the X slot (mouseif.c:250-252)
//             bit 5 (SHL) 1 = the high nibble (mouseif.c:267-271)
//   0x7FDB  Port B  write: portb latch; read (B = input): 0x40 (the constant
//           mouseif_i7fdb answers, the ITF's BANK4@0xF824E test), else the
//           portb latch (mouseif.c:279-287)
//   0x7FDD  Port C  write: setportc (below); read: the portc latch masked by
//           the mode - C-upper input (mode bit 3) masks to 0x1F, C-lower input
//           (mode bit 0) REPLACES the low nibble with 0x08 | the three DIP
//           strap bits, which NP2kai COMPUTES from its software-DIP bank and
//           this module takes as the `dip_strap` port (mouseif.c:289-307; see
//           the strap paragraph at the end of this header)
//   0x7FDF  control write ONLY (reads open bus 0xFF): bit 7 set is an 8255
//           MODE write - which resets the Port C output latch to 0 (see below)
//           - bit 7 clear is the 8255 bit set/reset form on one Port C bit,
//           index (dat >> 1) & 7, value dat & 1 (mouseif.c:197-218)
//   0xBFDB  write ONLY: the interrupt timing field, dat & 3 (mouseif.c:309-312)
//
// Buttons (mouseif_i7fd9's upper nibble, mouseif.c:228-238): L at bit 7 and R
// at bit 5, ACTIVE LOW, from mousemng's uPD8255A_LEFTBIT/uPD8255A_RIGHTBIT
// (sdl/mousemng.h:2-5, initialised "pressed bits SET = released" in
// sdl/mousemng.c:54). Bit 6 is the MIDDLE button (active low) - MAME documents
// the three-button layout as L/M/R on bits 7/6/5 (pc9801.cpp:1545-1552, "MIDDLE
// ... Undocumented, most PC98 mice don't have it") and NP2kai's read forces
// bit 6 HIGH ("for shizuku", mouseif.c:235), which is exactly "middle always
// released" for its two-button host. So with the MiSTer middle button up this
// read is BIT-IDENTICAL to NP2kai's; middle pressed clears bit 6 and is the one
// behaviour NP2kai cannot express (its host never reports a middle button -
// sdl/mousemng.c:70-87 maps only SDL left/right), sourced from MAME alone.
// Bit 4 is hardwired 0 as NP2kai's `ret &= 0xf0` leaves it (mouseif.c:233).
//
// Motion: the host's per-packet deltas accumulate into the x/y counters
// (SINT16, wrapping - software in the wild reads the WRAPPED nibbles; NP2kai's
// own comment at mouseif.c:150-152 says some software ASSUMES the overflow).
// A Port C bit-7 rising edge latches clamp(x, -128, 127) per axis and clears
// the counters (mouseif.c:144-163), and arms a four-read guard: while
// mouseif_limitcounter > 0 the value a 0x7FD9 read selects is clamped to
// [-128, 127] and the guard decrements per read (mouseif.c:253-266). The
// np2cfg.slowmous [-16, 15] variant (mouseif.c:254-258) is a config option and
// is not modelled, and neither is NP2kai's rx/ry host-delta PACING
// (calc_mousexy, mouseif.c:64-129): that exists to spread a host packet over
// ~18 ms because some games truncate the data (mouseif.c:13-15), it changes no
// protocol total, and real quadrature counters accumulate in real time.
//
// Interrupts (mouseint, mouseif.c:131-140): while Port C bit 4 is CLEAR
// (INT#, active low - MAME pc9801.cpp:1558-1560) a periodic event raises
// pic_setirq(0x0d) - IRQ13, the slave PIC's IR5 - every
// (realclock / 120) << timing emulated CPU clocks (mouseif.c:344-348), i.e.
// 120 Hz at timing 0 scaled by 2^timing (MAME's own "(120 >> x) Hz",
// pc9801.cpp:1663-1668, agrees; qemu models the same 120 Hz with the field as
// a TODO, pc98-mouse.c:83-85). This core runs the period on clk_sys wall time
// - (SYS_CLOCK_HZ / 120) << timing - the same translation pc9821_pit makes for
// the 8253. The event is armed by the bit-4 falling edge in setportc
// (mouseif.c:164-173) and by mouseif_sync's rev.79 revival (mouseif.c:55-61),
// so the converged rule here is "armed whenever INT# is enabled and not
// already armed"; when the event expires MASKED it dies without a pulse
// (mouseint's `if (!(portc & 0x10))`) and re-arms on the next enable.
//
// The Port C strap nibble is DERIVED, not a constant. mouseif_i7fdd ORs 0x08 with
// three bits it computes from `pccore.dipsw[]` (io/mouseif.c:296-303):
//
//   bit 2   <- dipsw[2] bit 7      (the byte NP2kai also answers at 0x8E1E bit 4,
//                                   `(dipsw[2] & 0x80) >> 3`, io/dipsw.c:105-111)
//   bits 1:0 <- ~dipsw[0] bits 5:4
//
// and this core's software-DIP store holds the same fields - pc9821_iobus's sdip[]
// is the banked form of that same bank - so they reach this module as `dip_strap`,
// taken from the ACTIVE bank by pc9821_iobus. With the measured power-up image
// (docs/probes/PORTS.TXT:258: 0x841E = 0x7C, 0x8E1E = 0x49) all three bits are 0,
// so the power-up Port C read is 0xF8, NOT the 0xFB this module answered while the
// straps were the hardcoded 0x03 - a value no bank of that store yields at power-up.
// qemu-pc98 agrees on the constant half (`ret |= 0x08`,
// hw/input/pc98-mouse.c:274-291, with the straps left as a TODO) and so does the
// machine's own 0x8E1E bit 4. NO CAPTURE OF 0x7FDD EXISTS in this tree - the
// ioprobe reads only 0x7FD9 and does not log this byte - so the byte rests on
// NP2kai over the modelled DIP bytes; a probe row that reads it is owed (/MODEW).
//
// The mode-write Port C reset is NP2kai's EXACT behaviour and qemu's, not an
// artifact: mouseif_o7fdf ends in `setportc(portc)` with its local portc = 0 in
// the mode branch (mouseif.c:197-216), and qemu's pc98_mouse_ctrl_write does
// `pc98_mouse_set_portc(s, 0)` "per the 8255, also resets the Port C output
// latch to 0" (hw/input/pc98-mouse.c) - the uPD8255 mode-set clears the output
// latches. A real-machine probe would be the stronger anchor; both
// software references are unambiguous and agree, so the
// divergence is fixed toward them and the probe (/MODEW) stays owed as the
// final anchor.

`default_nettype none

module pc9821_mouse #(
    parameter [31:0] SYS_CLOCK_HZ = 32'd50_000_000
) (
    input  wire        clk,
    input  wire        reset,        // synchronous, active high

    // The I/O port, driven by pc9821_iobus's S_BYTE strobes exactly like
    // pc9821_fdc: wr/rd are one-cycle strobes already qualified with cs.
    input  wire        cs,
    input  wire [2:0]  addr,         // 0..3 = 0x7FD9/DB/DD/DF (port_addr[2:1]),
    input  wire        wr,           // 4 = 0xBFDB
    input  wire        rd,
    input  wire [7:0]  din,
    output wire [7:0]  dout,

    // The three software-DIP strap bits mouseif_i7fdd's low nibble reports
    // (mouseif.c:296-303), from the ACTIVE bank of pc9821_iobus's SDIP store -
    // {bit 2, bits 1:0} = {dipsw[2] bit 7, ~dipsw[0] bits 5:4} on that bank's
    // 0x8E1E/0x841E bytes, which the store already holds as data bits. The
    // derivation is in pc9821_iobus (it owns the store); the header says why it
    // is derived rather than hardcoded.
    input  wire [2:0]  dip_strap,

    // hps_io's parsed PS/2 mouse packet (sys/hps_io.sv:121-122, 368-370):
    // [24] toggles once per packet, [23:16] = Y delta (PS/2: positive = up),
    // [15:8] = X delta (positive = right), [2:0] = {middle, right, left},
    // 1 = pressed. The PC-98 counters are x positive = right, y positive =
    // DOWN (NP2kai feeds SDL's down-positive yrel straight into mouseif.y,
    // sdl/mousemng.c:229-234), so Y is negated at the packet edge below.
    // [5:4] are the Y/X SIGN bits of the 9-bit deltas (below); [7:6] overflow and [3]
    // the constant 1 are not used.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [24:0] ps2_mouse,
    /* verilator lint_on UNUSEDSIGNAL */

    // One clk_sys pulse per periodic interrupt event - pc9821_pic latches the
    // request on the rising edge (ir_set = ir_in & ~ir_prev), the same pulse
    // shape qemu's pc98_mouse_tick raises and lowers.
    output wire        irq
);

  localparam [31:0] TICKS_120HZ = SYS_CLOCK_HZ / 32'd120;   // mouseif.c:346
  // The counter only ever holds `period - 1`, whose largest value is
  // (SYS_CLOCK_HZ/120) << 3 (timing 3): 3,333,327 at 50 MHz and 7,999,999 at
  // 120 MHz, so 32 bits were ten wider than the part ever needs. The width is
  // derived from the largest PERIOD (not period-1) so the `period - 1` does not
  // wrap when 8*(SYS_CLOCK_HZ/120) lands exactly on a power of two.
  localparam integer MOUSE_TICKS_MAX = (SYS_CLOCK_HZ / 32'd120) << 3;
  localparam integer MOUSE_TICK_W = $clog2(MOUSE_TICKS_MAX + 1);

  // ---- the uPD8255 register file (mouseif_reset, io/mouseif.c:317-330) ----
  reg [7:0] porta, portb, portc;
  /* verilator lint_off UNUSEDSIGNAL */   // NP2kai's read model consults only
  reg [7:0] mode;                       // the four DIRECTION bits (4/3/1/0,
  /* verilator lint_on UNUSEDSIGNAL */    // lsidef.h:9-16); the 8255 group/mode
                                          // select bits shape no mouseif read
  reg [1:0] timing;                 // 0xBFDB's dat & 3 (mouseif.c:309-312)
  // The latched counters are 8-bit because setportc clamps them to [-128, 127]
  // at the latch (mouseif.c:153-162); they reset to -1 (mouseif.c:325-326).
  reg signed [7:0]  latch_x, latch_y;
  // The live counters are 16-bit because the limitcounter read guard clamps the
  // SELECTED 16-bit value (mouseif.c:253-266) - modelling them 8-bit wrapped
  // would answer a clamped read of, say, +496 as its low byte instead of 127.
  reg signed [15:0] cnt_x, cnt_y;
  reg [2:0] limitcounter;           // 4 -> 0 (mouseif.c:150-151, 253-266)
  // Buttons in the read's upper nibble: {L_n, M_n, R_n, 0}, all released =
  // 0xE = uPD8255A_LEFTBIT | RIGHTBIT extended with the middle bit MAME names
  // (see the header). Latched per host packet, the read shape of
  // mouseif_sync's `mouseif.b = mousemng_getstat(...)` (mouseif.c:25).
  reg [3:0] buttons;

  // ---- the periodic IRQ13 event (mouseint, mouseif.c:131-140) ----
  reg        tick_armed;            // nevent_iswork
  reg [MOUSE_TICK_W-1:0] tick_ctr;
  reg        irq_r;

  wire int_en = ~portc[4];          // INT# active low (mouseif.c:164-165)
  wire [MOUSE_TICK_W-1:0] period = TICKS_120HZ[MOUSE_TICK_W-1:0] << timing;   // intrclock << timing

  // ---- the host packet edge (hps_io's toggle-coded event) ----
  reg        ps2_tog;
  wire       pkt = ps2_mouse[24] != ps2_tog;
  // A PS/2 delta is 9-bit two's complement: the sign is byte 0 bit 4 (X) / bit 5 (Y) and
  // the delta byte is the low 8 bits, so +-128..255 arrive intact. Main_MiSTer user_io.cpp
  // user_io_mouse: "YOvfl, XOvfl, dy8, dx8, 1, mbtn, rbtn, lbtn", `ps2_mouse[0] |= (x < 0) ?
  // 0x10 : 0x00;` with x clamped to +-255. Extending bit 7 of the delta byte turned a fast
  // +200 into -56 (tb_pc9821_mouse_sign).
  wire signed [15:0] x_ext = {{8{ps2_mouse[4]}}, ps2_mouse[15:8]};
  wire signed [15:0] y_ext = {{8{ps2_mouse[5]}}, ps2_mouse[23:16]};
  wire signed [15:0] dx = x_ext;
  // PS/2 Y is positive = up; the PC-98 counter is positive = down (header).
  wire signed [15:0] dy = -y_ext;

  // ---- the write side: one setportc path for both entry forms ----
  // mouseif_o7fdd is setportc(dat); mouseif_o7fdf's BSR form computes
  // `portc bit (dat>>1)&7 = dat&1` and calls setportc(portc), and its MODE form
  // calls setportc(0) (mouseif.c:197-216). portc_in folds all three writes
  // into one next-state expression so the bit-7 latch edge is tested against
  // the LIVE latch no matter which port wrote it.
  wire [7:0] bsr_portc = din[0] ? (portc |  (8'h01 << din[3:1]))
                                : (portc & ~(8'h01 << din[3:1]));
  wire portc_we = wr && ((addr == 3'd2) || (addr == 3'd3));
  wire [7:0] portc_in = (addr == 3'd2) ? din : (din[7] ? 8'h00 : bsr_portc);
  wire latch_edge = portc_we && portc_in[7] && ~portc[7];   // setportc:144

  // ---- the read composition (mouseif_i7fd9, mouseif.c:228-275) ----
  wire rd_a_data = rd && (addr == 3'd0) && mode[4];   // a 0x7FD9 read of MOUSE data
  wire signed [15:0] sel_axis = portc[6] ? (portc[7] ? {{8{latch_y[7]}}, latch_y} : cnt_y)
                                         : (portc[7] ? {{8{latch_x[7]}}, latch_x} : cnt_x);
  // The limitcounter guard (mouseif.c:253-266): clamp the selected value while
  // it runs; once expired the WRAPPED value passes (the overflow-assuming
  // software mouseif.c:150-152 protects). slowmous' tighter clamp is a config
  // option and is not modelled (header).
  wire [7:0] sel_byte = (limitcounter != 3'd0)
                      ? ((sel_axis > 16'sd127) ? 8'h7F :
                         (sel_axis < -16'sd128) ? 8'h80 : sel_axis[7:0])
                      : sel_axis[7:0];
  wire [3:0] data_nibble = portc[5] ? sel_byte[7:4] : sel_byte[3:0];

  // mouseif_i7fdd (mouseif.c:289-307) applies the two masks in sequence, so with
  // BOTH halves an input the answer is 0x08 | the DIP strap bits (NP2kai's 0x08 at
  // mouseif.c:299, the straps computed at :300-301) and with C-upper an input alone
  // it is the latch masked to 0x1F.
  wire [7:0] pc_masked = mode[3] ? (portc & 8'h1F) : portc;
  wire [7:0] portc_read = mode[0] ? ((pc_masked & 8'hF0) | 8'h08 | {5'd0, dip_strap})
                                  : pc_masked;

  // cs qualifies the read mux the way pc9821_fdc does; the wr/rd strobes are
  // already qualified with it by pc9821_iobus.
  assign dout = !cs     ? 8'hFF                                            :
                (addr == 3'd0) ? (mode[4] ? {buttons, data_nibble} : porta) :
                (addr == 3'd1) ? (mode[1] ? 8'h40 : portb)                 :
                (addr == 3'd2) ? portc_read                                 :
                8'hFF;   // 0x7FDF and 0xBFDB are write-only (mouseif_bind:332-342)

  assign irq = irq_r;

  // One sequential block, one next-state expression per register: the packet
  // edge and the latch edge both reach the counters (the R4 merge below), and
  // the latch edge and the 0x7FD9 read side effect both reach limitcounter.
  wire tick_fire = tick_armed && (tick_ctr == {MOUSE_TICK_W{1'b0}}) && int_en;
  wire tick_die  = tick_armed && (tick_ctr == {MOUSE_TICK_W{1'b0}}) && ~int_en;
  wire tick_arm  = ~tick_armed && int_en;

  always @(posedge clk) begin
    if (reset) begin
      porta <= 8'h00; portb <= 8'h00; portc <= 8'hF0;   // mouseif_reset:319-323
      mode  <= 8'h93;
      timing <= 2'd0;
      latch_x <= 8'hFF; latch_y <= 8'hFF;               // -1: mouseif_reset:325-326
      cnt_x <= 16'sd0; cnt_y <= 16'sd0;
      limitcounter <= 3'd0;
      buttons <= 4'b1110;      // L/M/R released (mousemng.c:54 + the MAME bit 6)
      ps2_tog <= 1'b0;
      tick_armed <= 1'b0; tick_ctr <= {MOUSE_TICK_W{1'b0}}; irq_r <= 1'b0;
    end else begin
      ps2_tog <= ps2_mouse[24];

      // The 8255 latches and setportc's side effects.
      if (wr && (addr == 3'd0)) porta <= din;
      if (wr && (addr == 3'd1)) portb <= din;
      if (portc_we) portc <= portc_in;
      if (wr && (addr == 3'd3) && din[7]) mode <= din;
      if (wr && (addr == 3'd4)) timing <= din[1:0];     // mouseif_obfdb:309-312

      // setportc's bit-7 latch edge (mouseif.c:144-163): snapshot clamp(x/-128
      // ..127), clear the counters, arm the four-read guard.
      if (latch_edge) begin
        latch_x <= (cnt_x > 16'sd127) ? 8'h7F : (cnt_x < -16'sd128) ? 8'h80 : cnt_x[7:0];
        latch_y <= (cnt_y > 16'sd127) ? 8'h7F : (cnt_y < -16'sd128) ? 8'h80 : cnt_y[7:0];
      end

      // R4 MERGE: a host packet landing in the latch edge's own cycle starts
      // the NEW accumulation and is neither latched nor lost. NP2kai cannot
      // express the coincidence (its host events and port writes are
      // serialized), and its closest shape - mouseif_sync leaving the newest
      // delta in rx for the next sync (mouseif.c:20-25) - keeps the newest
      // packet OUT of the just-taken latch, which is the rule picked here.
      // tb_pc9821_mouse sweeps a packet across the latch write to pin it.
      cnt_x <= latch_edge ? (pkt ? dx : 16'sd0) : (pkt ? (cnt_x + dx) : cnt_x);
      cnt_y <= latch_edge ? (pkt ? dy : 16'sd0) : (pkt ? (cnt_y + dy) : cnt_y);

      // mouseif_i7fd9's read side effect (mouseif.c:253-266): the guard runs
      // only on a 0x7FD9 DATA read, and the latch edge reloads it (its two
      // writers are mutually exclusive strobes: the edge is a write, the
      // decrement a read).
      limitcounter <= latch_edge ? 3'd4
                    : (rd_a_data && (limitcounter != 3'd0)) ? (limitcounter - 3'd1)
                    : limitcounter;

      // The buttons latch (mouseif.c:25): {L_n, M_n, R_n, 0}.
      if (pkt) buttons <= {~ps2_mouse[0], ~ps2_mouse[2], ~ps2_mouse[1], 1'b0};

      // The periodic IRQ13 event. tick_ctr folds arm/reload/expire (the only
      // events that load it) against the decrement, and irq_r IS the fire
      // condition registered once (no default-clear + set pair). The load is
      // period-1 because the expiry cycle ITSELF is one of the period's ticks:
      // period decrements reach 0 in period-1 edges and the fire edge is the
      // period-th, so pulse-to-pulse is exactly `period` clk_sys.
      tick_ctr <= (tick_fire || tick_arm || (tick_ctr == {MOUSE_TICK_W{1'b0}})) ? (period - 1'b1)
                : (tick_ctr - 1'b1);
      tick_armed <= tick_arm ? 1'b1 : (tick_die ? 1'b0 : tick_armed);
      irq_r <= tick_fire;
    end
  end

`ifdef VERILATOR
  // R8: the invariants of the two events that cross this boundary (the I/O
  // strobes in, the IRQ pulse out).
  reg irq_q;
  always @(posedge clk) begin
    if (reset) irq_q <= 1'b0;
    else irq_q <= irq_r;
    if (!reset && wr && rd)
      $error("pc9821_mouse: wr and rd strobes in the same cycle - the S_BYTE strobes are exclusive");
    if (!reset && irq_r && irq_q)
      $error("pc9821_mouse: back-to-back IRQ13 pulses - one pulse per (SYS_CLOCK_HZ/120)<<timing period");
  end
`endif

endmodule

`default_nettype wire
