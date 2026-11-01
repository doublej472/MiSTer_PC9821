// The 9-pin Atari game port on the sound board, as the PC-9801-118 card answers it at
// 0x1480-0x1487: a WRITE starts the axis one-shots and a READ samples them while they run
// down (NP2kai cbus/board118.c:333-367 gameport_o1480, :369-458 gameport_i1480, under
// SUPPORT_GAMEPORT). The card does not distinguish the eight addresses ("1480h-1487h, any
// of them is fine", board118.c:816-822 attaches both handlers to all eight), so this module
// has no address input: pc9821_device_select's gameport_cs is the claim.
//
// The byte is the IBM game port's, which is also the layout of the inputs this core already
// carries (ao486 rtl/soc/joystick.v, whose mapping z486_mister.sv copied): bit0 j1 X,
// bit1 j1 Y, bit2 j2 X, bit3 j2 Y, 1 while that axis's one-shot runs down, and bit4..bit7
// the four buttons, active low. NP2kai's single-stick form assigns bits 0/1/4/5 the same
// way, leaves bits 2/3 at 1 and puts its rapid-fire copy of the same two buttons in bits
// 6/7 (board118.c:341); the second stick's fields are this core's.

`default_nettype none

module pc9821_gameport #(
    parameter integer SYS_CLOCK_HZ = 50_000_000
) (
    input  wire        clk,
    input  wire        reset,        // synchronous, active high

    // Device bus, driven by pc9821_system: a write is a trigger, a read is a sample.
    input  wire        io_wr,
    input  wire        io_rd,
    output wire  [7:0] io_dout,

    // The OSD's joystick controls. z486_mister.sv reads them out of `status` and maps
    // joystick_0/1 and the two analog words onto these ports; that mapping is there.
    //
    // HARD-WIRED TO THE MACHINE DEFAULTS: no CONF_STR entry declares any of the three
    // fields below, and an undeclared status range is hard-wired to 0, so today they are
    // dis = 2'b00 (both sticks present), mode = 2'b00 (two buttons each) and timed = 0
    // (the IBM timed one-shot) - exactly the PC-98 pad this machine has. The arms are not
    // dead code, they are unreachable: exposing them is an open decision, priced at
    // +28 ALMs module-alone, and upstream
    // ao486 exposes all of its joystick fields (`P2oCD,P2oFG,P2oQR,P2oH,P2oI`). The two
    // fields that shape the analog words in z486_mister.sv (status[48:47] and the
    // per-stick disable on status[47]/status[49]) are undeclared for the same reason.
    input  wire  [1:0] dis,          // per stick: 1 = no joystick on that stick
    input  wire  [1:0] mode,         // 0 = 2 buttons each, 1 = 4 buttons on stick 1, 3 = none
    input  wire  [1:0] timed,        // 0 = the IBM timed form, 1..3 = the count-on-read forms
    /* verilator lint_off UNUSEDSIGNAL */   // a game port has two button lines, or four on
    // stick 1: the gamepad's start/select/shoulder bits have no pin on the connector, and
    // dig_2's bits 7:6 are not the port's either, because 4-button mode reads those from
    // stick 1. The 14-bit word is z486_mister.sv's and is wired whole.
    input  wire [13:0] dig_1,        // joystick_0[13:0]: 0 R, 1 L, 2 D, 3 U, 4 A, 5 B, 6 X, 7 Y
    input  wire [13:0] dig_2,        // joystick_1[13:0], the same order
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [15:0] ana_1,        // {y[7:0], x[7:0]}, signed 8-bit
    input  wire [15:0] ana_2,

    // The sound board's own read of the same connector, for the OPNA's register 0x0E:
    // six switch lines, active low - up, down, left, right, button 1, button 2
    // (NP2kai sound/fmboard.c:54-90 fmboard_getjoy, whose result that register returns
    // masked to 0x3F). Stick 1 only: the card has one connector and NP2kai one pad.
    output wire  [5:0] switch_lines
);

  // ---- the axis positions -----------------------------------------------------------
  // A stick's axes come from the analog stick once it moves past the activity threshold,
  // and from the D-pad again when a direction is held: ao486's joystick.v:203-206 latch,
  // for a pad that reports both. The threshold and the choice are its.
  localparam signed [7:0] ANA_ACTIVITY = 8'sd60;
  wire signed [7:0] ax_1 = ana_1[7:0];
  wire signed [7:0] ay_1 = ana_1[15:8];
  wire signed [7:0] ax_2 = ana_2[7:0];
  wire signed [7:0] ay_2 = ana_2[15:8];
  wire ana_1_moved = (ax_1 > ANA_ACTIVITY) || (ax_1 < -ANA_ACTIVITY) ||
                     (ay_1 > ANA_ACTIVITY) || (ay_1 < -ANA_ACTIVITY);
  wire ana_2_moved = (ax_2 > ANA_ACTIVITY) || (ax_2 < -ANA_ACTIVITY) ||
                     (ay_2 > ANA_ACTIVITY) || (ay_2 < -ANA_ACTIVITY);
  reg ana_mode_1, ana_mode_2;

  always @(posedge clk) begin
    if (reset) begin
      ana_mode_1 <= 1'b0;
      ana_mode_2 <= 1'b0;
    end else begin
      if (ana_1_moved)    ana_mode_1 <= 1'b1;
      else if (|dig_1[3:0]) ana_mode_1 <= 1'b0;
      if (ana_2_moved)    ana_mode_2 <= 1'b1;
      else if (|dig_2[3:0]) ana_mode_2 <= 1'b0;
    end
  end

  // 0..255 for one axis: the analog value while it is the source, else the D-pad direction
  // at its end stop, else centre.
  function automatic [7:0] axis_pos(input signed [7:0] v, input analog,
                                    input end_lo, input end_hi);
    begin
      if (analog)      axis_pos = {~v[7], v[6:0]};   // signed -128..127 -> 0..255
      else if (end_lo) axis_pos = 8'd0;
      else if (end_hi) axis_pos = 8'd255;
      else             axis_pos = 8'd128;
    end
  endfunction

  wire [7:0] pos_1x = axis_pos(ax_1, ana_mode_1, dig_1[1], dig_1[0]);   // left 0, right 255
  wire [7:0] pos_1y = axis_pos(ay_1, ana_mode_1, dig_1[3], dig_1[2]);   // up 0, down 255
  wire [7:0] pos_2x = axis_pos(ax_2, ana_mode_2, dig_2[1], dig_2[0]);
  wire [7:0] pos_2y = axis_pos(ay_2, ana_mode_2, dig_2[3], dig_2[2]);

  // ---- the discharge the position asks for ------------------------------------------
  // timed 0 is the IBM formula t = 24.2 us + 0.011 us * R, with R = 0..1000 the pot in
  // hundreds of ohms: 22..1022 ticks of 1.1 us. 1000/255 is expanded as
  // 4 - 1/16 - 1/64 - 1/256, ao486's approximation (its joystick.v:251-262, which is also
  // where this module's 1.1 us tick comes from). timed 1..3 are COUNT-ON-READ forms, for
  // games that count reads rather than time (ao486's joystick.v:269-296).
  // 22..1022 ticks, so 10 bits: the largest discharge is the pos==255 end stop's
  // 1000 + 22, and the widest pos<<2 term is 1020 (pos 255 takes the end stop).
  function automatic [9:0] discharge(input [7:0] pos, input [1:0] form);
    begin
      case (form)
        2'd0:    discharge = 10'd22 + ((pos == 8'd255) ? 10'd1000 :
                                       ({2'b00, pos} << 2) - ({2'b00, pos} >> 4) -
                                       ({2'b00, pos} >> 6) - ({2'b00, pos} >> 8));
        2'd1:    discharge = 10'd8 + ({2'b00, pos} >> 1) + ({2'b00, pos} >> 4) -
                             ({2'b00, pos} >> 7) - ({2'b00, pos} >> 7);
        2'd2:    discharge = {2'b00, pos};
        default: discharge = 10'd6 + {2'b00, pos};
      endcase
    end
  endfunction

  // The trigger restarts this tick too, so the first interval carries no phase the write
  // did not ask for. ao486 derives the same 1.1 us period from 909091/clock_rate.
  // The 1.1 us tick counter only ever reaches TICK_DIV-1 (55 at 50 MHz, 132 at
  // 120 MHz), so it needs $clog2(TICK_DIV) bits and not 16.
  localparam [15:0] TICK_DIV = 16'((SYS_CLOCK_HZ + 454_545) / 909_091);   // 55 at 50 MHz
  localparam integer TICKC_W  = $clog2(TICK_DIV);
  localparam [TICKC_W-1:0] TICK_LAST = TICKC_W'(TICK_DIV - 1);
  reg [TICKC_W-1:0] tick_cnt;
  wire tick = (tick_cnt == TICK_LAST);

  always @(posedge clk) begin
    if (reset || io_wr) tick_cnt <= {TICKC_W{1'b0}};
    else if (tick)      tick_cnt <= {TICKC_W{1'b0}};
    else                tick_cnt <= tick_cnt + 1'b1;
  end

  // ONE discharge chain, time-shared over the four axes. A free-running 2-bit phase walks
  // the chain through the four positions and latches each axis's result; a trigger write
  // loads all four counters on its own clk from those latches, exactly the four values the
  // four parallel chains loaded. The chain therefore sees a position that has been stable
  // for up to four clk: the OSD holds a stick position for many frames and a guest reaches
  // this port only through a 186-clk device access, so that latency is not observable.
  reg [1:0]  disch_phase;
  reg [7:0]  disch_pos;
  reg [9:0] disch_1x, disch_1y, disch_2x, disch_2y;
  always @* begin
    case (disch_phase)
      2'd0:    disch_pos = pos_1x;
      2'd1:    disch_pos = pos_1y;
      2'd2:    disch_pos = pos_2x;
      default: disch_pos = pos_2y;
    endcase
  end
  wire [9:0] disch = discharge(disch_pos, timed);

  // A count of 0 means the discharge has completed and the axis bit reads 0 until the next
  // trigger; nothing re-arms the one-shot.
  reg [9:0] cnt_1x, cnt_1y, cnt_2x, cnt_2y;
  wire discharge_now = (timed == 2'd0) ? tick : io_rd;

  always @(posedge clk) begin
    if (reset) begin
      disch_phase <= 2'd0;
      disch_1x <= 10'd0;
      disch_1y <= 10'd0;
      disch_2x <= 10'd0;
      disch_2y <= 10'd0;
    end else begin
      disch_phase <= disch_phase + 2'd1;
      case (disch_phase)
        2'd0:    disch_1x  <= disch;
        2'd1:    disch_1y <= disch;
        2'd2:    disch_2x <= disch;
        default: disch_2y <= disch;
      endcase
    end
  end

  always @(posedge clk) begin
    if (reset) begin
      cnt_1x <= 10'd0;
      cnt_1y <= 10'd0;
      cnt_2x <= 10'd0;
      cnt_2y <= 10'd0;
    end else if (io_wr) begin
      cnt_1x <= disch_1x;
      cnt_1y <= disch_1y;
      cnt_2x <= disch_2x;
      cnt_2y <= disch_2y;
    end else if (discharge_now) begin
      if (cnt_1x != 10'd0) cnt_1x <= cnt_1x - 10'd1;
      if (cnt_1y != 10'd0) cnt_1y <= cnt_1y - 10'd1;
      if (cnt_2x != 10'd0) cnt_2x <= cnt_2x - 10'd1;
      if (cnt_2y != 10'd0) cnt_2y <= cnt_2y - 10'd1;
    end
  end

  // ---- the byte ---------------------------------------------------------------------
  wire [3:0] axis_bits = {cnt_2y != 10'd0, cnt_2x != 10'd0,
                          cnt_1y != 10'd0, cnt_1x != 10'd0};
  wire m2_buttons = (mode == 2'd1);
  wire [3:0] button_bits = ~{ m2_buttons ? dig_1[7] : dig_2[5],
                              m2_buttons ? dig_1[6] : dig_2[4],
                              dig_1[5], dig_1[4] };
  // In 4-button mode bits 6/7 are STICK 1's third and fourth buttons, so the mask that
  // covers them follows the stick that owns them: dis[0] there, dis[1] in the 2-button
  // mode where they are stick 2's. ao486's mask (joystick.v:67) tests only dis[1], so a
  // DISABLED stick 1 leaked its buttons through 6/7 -- a latent defect here, because
  // this module's contract is that a disabled stick reads ABSENT.
  // A DISABLED stick reads as ABSENT: axis bits 1 (an unplugged axis never runs down),
  // buttons released, so a disabled port answers 0xFF -- what NP2kai answers with no
  // joystick at all (board118.c:383-386). An enabled but untriggered stick reads its axes
  // 0, the untriggered one-shot's state and NP2kai's own power-up value (board118.c:312).
  wire dis_34 = m2_buttons ? dis[0] : dis[1];
  wire [7:0] dis_mask = {{2{dis_34}}, {2{dis[0]}}, {2{dis[1]}}, {2{dis[0]}}};

  assign io_dout = (mode == 2'd3) ? 8'hFF : ({button_bits, axis_bits} | dis_mask);

  // Stick 1's switch lines; a disabled stick reads released. The D-pad is the only source:
  // these are the connector's switches, and an analog pot closes none, so the analog stick
  // moves the axes above and not this byte.
  assign switch_lines = dis[0] ? 6'b111111 :
                        ~{dig_1[5], dig_1[4], dig_1[0], dig_1[1], dig_1[2], dig_1[3]};

endmodule

`default_nettype wire
