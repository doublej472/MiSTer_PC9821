// The Roland MPU-PC98II at 0xE0D0 (data) / 0xE0D2 (status, command): the C-bus MIDI card the
// PC-98 software commonly asks for, modelled at the register level for the paths a
// MIDI driver actually uses.
//
// WHICH CARD, AND WHY THOSE TWO ADDRESSES. MMD.COM (KAJA's M.M.D. 2.2f, the driver TH02's own
// batch file loads) hard-codes 0xE0D0 and 0xE0D2 and has no fallback scan; NP2kai computes the
// same base (cbus/mpu98ii.c:1151 `0xc0d0 | ((opt & 0xf0) << 6)`, default 0xE0D0 at
// pccore.c:873) and attaches the standalone card at `port` and `port | 2` (:1177-1179, i.e.
// +0/+2, NOT +0/+1 - the -118 variant is the +0/+1 pair and is not this card). MAME's PC-9821
// map lists the same 16 option windows as `<undefined>`, commented out
// (mame/src/mame/nec/pc9821.cpp:767-782). The four-byte window MAME's comment implies is NOT
// answered: NP2kai attaches only two ports, so 0xE0D1/0xE0D3 stay undecoded here (a
// recorded divergence).
//
// WHAT IS MODELLED. MMD never enters UART mode (a scan of all 7,071 bytes finds no `mov al,3F`;
// REPORT sec.2), so it speaks the intelligent-mode byte-injection subset: `0xD0` (want to send
// data) + data-port bytes for a channel message, `0xDF` + `0xF0..0xF7` for system exclusive,
// `0xE0/0xE1/0xE2/0xE7` + one follow byte, and it requires an ACK (0xFE) for EVERY command
// (NP2kai mpu98ii.c:1030 `setrecvdata(MPUMSG_ACK)`) plus an H.CLK byte (0xFD) on the card's IRQ
// before it will admit a board is present. This module is that subset plus the register
// read-back the driver polls, with UART mode (0x3F) as the degenerate case. The internal
// SEQUENCER (tracks, reference table, play/record) is deliberately absent: nothing in this tree
// drives it (MMD plays through 0xD0/0xDF, not through 0xA0+/0x00-0x2F).
//
// THE READ-BACK IS THE POINT (AGENTS.md: the read side is the systematic weak spot). MMD's two
// primitives, verified byte for byte in the driver image:
//   read  (CS:0x01C6) in al,0xE0D2 / test al,al / js    -> spin while bit 7 is SET (nothing to
//                      read), then in al,0xE0D0 -> take the byte. No timeout.
//   write (CS:0x01D3) in al,0xE0D2 / test al,0x40 / jnz -> spin while bit 6 (BUSY) is SET,
//                      then out the command to 0xE0D2 or the data byte to 0xE0D0.
// So the status polarities (bit 7 = response register EMPTY, NP2kai mpu98ii.c:1101-1104 and
// MAME mpu401.cpp:58's `STAT_RX_EMPTY`), the BUSY bit's meaning, and the data register's
// one-byte-at-a-time drain are what the driver hangs on; the bench pins all three.
//
// THE TWO TIMES ARE REAL TIMES (AGENTS.md: rates come from a device, not from clk_sys counts).
// The 31250-baud line rate and the H.CLK tick are both derived from SYS_CLOCK_HZ, so raising
// clk_sys cannot change either - tb_pc9821_sysclk_invariance runs the two-clock check.
`default_nettype none

module pc9821_mpu #(
    parameter integer SYS_CLOCK_HZ = 50_000_000
) (
    input  wire        clk,
    input  wire        reset,        // synchronous, active high

    // Device bus, driven by pc9821_system. cs is pc9821_device_select's mpu_cs, so a strobe
    // means addr is 0xE0D0 or 0xE0D2. wr/rd are pc9821_iobus's one-cycle S_BYTE strobes.
    input  wire        cs,
    input  wire [15:0] addr,
    input  wire        wr,
    input  wire        rd,
    input  wire  [7:0] din,
    output wire  [7:0] dout,

    // The serial MIDI line (31250 baud, 8N1, LSB first): the same signal the framework's UART
    // port and sys/mt32pi.sv's `midi_tx` both take. Both are the LINE, not a byte handshake
    // (sys/mt32pi.sv:56 (assign USER_OUT[1]   = midi_tx;)), which is why the core serialises.
    output wire        uart_tx,
    // Asserted while a response byte is queued - NP2kai raises it on the enqueue and clears it
    // when the queue drains (mpu98ii.c:236-241, :1078-1081). The board's default is IRQ6
    // (mpu98ii.c:98 `mpuirqnum[4] = {3,5,6,12}`, indexed by the option's low two bits; the
    // default option 0x82 at pccore.c:873 selects index 2).
    output wire        irq
);

  // ---- the two ports ---------------------------------------------------------------------
  wire cmd_wr = cs && wr && (addr == 16'hE0D2);
  wire dat_wr = cs && wr && (addr == 16'hE0D0);
  wire dat_rd = cs && rd && (addr == 16'hE0D0);

  // ---- static parameters -----------------------------------------------------------------
  // The response queue, 16 bytes rather than NP2kai's 128 (MPU98_RECVBUFS = 1<<7,
  // cbus/mpu98ii.h:6): the only producers this model has are the command ACK and the H.CLK
  // tick, both drained one at a time by the driver, so a flop bank is the right shape and a
  // block RAM would not fit an asynchronous read anyway. A full queue DROPS, which is NP2kai's
  // own behaviour (`if (r->cnt < MPU98_RECVBUFS)`, :178-181).
  localparam integer RQ_DEPTH = 16;
  // The MIDI-out queue, 32 bytes, a BLOCK MEMORY (this design is LAB-bound). The card's own
  // deepest burst is the 0xFF/0x3F reset's 48-byte all-notes-off run (sendmpureset, :223-233),
  // which the generator below PACES into the queue rather than demanding 48 slots at once. What
  // a caller beyond the credit would lose, the real card loses too: its BUSY is a credit counter
  // (MPU98_WRITEBUFFER, :107), and every MMD write polls it.
  localparam integer TX_DEPTH = 32;
  // NP2kai's stepclock (`realclock * 5 / l`, makeintclock :111-129, with
  // `l = tempo*2*reltempo/0x40 * inttimebase`, floored at 10). At the two configurations that
  // matter l is 1000 - the card's power-up default (tempo 100, inttimebase 120/24 = 5, reltempo
  // 0x40) and MMD's own (0xE0 250, 0xC2 2, reltempo 0x40) - so stepclock is SYS_CLOCK_HZ/200 in
  // both, and that is the static rate built here. The general tempo law is [OPEN]
  // (REPORT sec.7.4.3: the true law is capture-pending and no capture exists), so this is
  // deliberately the rate the reference gives for the driver that would use it.
  localparam integer HCLK_STEP_CYCLES_I = SYS_CLOCK_HZ / 200;
  localparam [19:0]  HCLK_STEP_CYCLES   = HCLK_STEP_CYCLES_I[19:0];

  // ---- state -----------------------------------------------------------------------------
  reg  [7:0]  rq [0:RQ_DEPTH-1];
  reg  [3:0]  rq_wr;
  reg  [3:0]  rq_rd;
  reg  [4:0]  rq_cnt;

  reg  [7:0]  txq [0:TX_DEPTH-1];   // indexed by the pointers' low 5 bits (TX_DEPTH 32)
  reg  [6:0]  tx_wr;
  reg  [6:0]  tx_rd;
  reg  [6:0]  tx_cnt;
  reg         tx_go;
  reg  [7:0]  tx_byte;

  // NP2kai's `mpu98.data`: a DATA-port read of an EMPTY queue returns the LAST byte returned,
  // not open bus (:1063-1071 returns mpu98.data; mpu98ii_reset sets it to MPUMSG_ACK, :1149).
  // MMD's presence probe depends on it: it reads 0xE0D0 and 0xE0D2, ANDs them, and calls the
  // board absent only when the result is all ones (CS:0x15AC), so 0xFE & 0x80 answers "present".
  reg  [7:0]  dat_latch;

  // The command/transfer state (NP2kai's MPUCMDP_* phases).
  localparam [1:0] PH_IDLE   = 2'd0,   // no transfer open
                   PH_FOLLOW = 2'd1,   // 0xE0..0xEF sent, one follow byte expected
                   PH_SHORT  = 2'd2,   // 0xD0..0xD7 sent, a channel message is assembled
                   PH_LONG   = 2'd3;   // 0xDF sent, a system message is assembled
  reg  [1:0]  phase;
  reg         uart_mode;         // 0x3F: the dumb byte pipe (mpu98ii.c:451-457)
  reg  [7:0]  cmd_prev;          // the command a follow byte belongs to (:1238 cmd.cmd)
  reg  [7:0]  msg_status;        // running status of the short message being assembled
  reg  [1:0]  msg_pos;           // index of the NEXT byte to store
  reg  [1:0]  msg_len;           // total bytes in the message being assembled
  reg  [7:0]  msg_buf [0:2];
  reg  [7:0]  snd_buf [0:2];     // a completed short message, on its way out
  reg  [1:0]  snd_pos;
  reg  [1:0]  snd_len;
  reg         snd_on;
  reg         long_first;        // the sysex's first byte has not arrived
  reg  [7:0]  long_head;         // that first byte, for the framing rule
  reg [10:0]  long_pos;
  reg         burst_on;          // the 0xFF/0x3F all-notes-off run is in progress
  reg  [3:0]  burst_ch;          // its channel, 0..15
  reg  [1:0]  burst_ph;          // 0 = 0xB0+ch, 1 = 0x7B, 2 = 0x00
  reg         pend_valid;        // a byte parked until the MIDI-out queue has room
  reg  [7:0]  pend_byte;
  reg         hclk_on;
  reg [19:0]  hclk_sub;          // cycles within one stepclock
  reg  [6:0]  hclk_tick;         // stepclocks within the current 0xE7 step
  reg  [6:0]  hclk_quarter;      // 1..64, from the 0xE7 follow byte
  reg  [1:0]  hclk_dither;       // the same byte's low two bits (hclk_step1's row)
  reg  [2:0]  hclk_phase;        // the four-phase dither's index
  reg         hclk_kick;         // one immediate tick on 0x95; see the note at its arm

  integer i;

  // ---- combinational views ---------------------------------------------------------------
  wire rq_empty = (rq_cnt == 5'd0);
  wire rq_full  = (rq_cnt == RQ_DEPTH[4:0]);
  // The head is presented combinationally: pc9821_system's device read mux samples the byte in
  // the S_BYTE cycle of the access, so a registered read would be one cycle late.
  wire [7:0] rq_head = rq[rq_rd];

  wire tx_empty = (tx_cnt == 7'd0);
  wire tx_room  = (tx_cnt != TX_DEPTH[6:0]);
  // BUSY, from NP2kai's credit: set while the card cannot take more (here, the queue is half
  // full, or a byte is parked waiting for room), so a caller that polls it paces itself. NP2kai
  // ALSO forces a one-byte-time transient BUSY on every command and data write (midicmdwait
  // :387-397); that is an artifact of its host-side write path rather than the card's input
  // buffer filling, and the driver polls BUSY BEFORE a write, so it is not observable and is
  // not modelled.
  wire tx_busy_level = (tx_cnt >= 7'd16);

  // The one producer allowed to write the MIDI-out queue this cycle: the reset burst outranks a
  // parked byte (it was requested first and its byte order is fixed), and the parked byte
  // outranks a message's, so arrival order is preserved.
  wire       tx_push_burst = burst_on && tx_room;
  wire       tx_push_snd   = !burst_on && snd_on && tx_room;
  wire       tx_push_pend  = !burst_on && !snd_on && pend_valid && tx_room;
  wire       tx_push       = tx_push_burst || tx_push_snd || tx_push_pend;
  wire [7:0] tx_push_byte  = tx_push_burst ?
                               ((burst_ph == 2'd0) ? (8'hB0 + {4'd0, burst_ch}) :
                                (burst_ph == 2'd1) ? 8'h7B : 8'h00) :
                             tx_push_snd ? snd_buf[snd_pos] : pend_byte;
  wire       tx_pop        = (!tx_go && !tx_empty);

  function automatic [1:0] short_len(input [3:0] nib);
    begin
      case (nib)
        4'h8, 4'h9, 4'hA, 4'hB, 4'hE: short_len = 2'd3;
        4'hC, 4'hD:                   short_len = 2'd2;
        4'hF:                         short_len = 2'd1;
        default:                      short_len = 2'd0;
      endcase
    end
  endfunction

  // The short-message byte arriving on the DATA port, resolved against NP2kai's sendmpumsg
  // (:777-812): a byte with bit 7 clear is a DATA byte under running status, so it lands at
  // index 1 with the stored status byte at index 0; a byte with bit 7 set is the status, lands
  // at 0, and refreshes the running status unless it is a system message (0xF0).
  wire       d_is_status = din[7];
  wire [1:0] d_idx = (msg_pos == 2'd0) ? (d_is_status ? 2'd0 : 2'd1) : msg_pos;
  wire [1:0] d_len = (msg_pos == 2'd0)
                     ? short_len(d_is_status ? din[7:4] : msg_status[7:4]) : msg_len;
  wire       d_done = (d_len != 2'd0) && ((d_idx + 2'd1) >= d_len);
  wire [7:0] mb0_next = (msg_pos == 2'd0) ? (d_is_status ? din : msg_status) : msg_buf[0];
  wire [7:0] mb1_next = (msg_pos == 2'd0) ? (d_is_status ? 8'h00 : din)
                                          : ((msg_pos == 2'd1) ? din : msg_buf[1]);
  wire [7:0] mb2_next = (msg_pos == 2'd2) ? din : msg_buf[2];

  // The 0xE7 follow byte's step: NP2kai's sethclk (:132-146) loads `quarter = n>>2` (64 when 0)
  // plus hclk_step1[n & 3][phase] (:103), and midiint emits one 0xFD per hclk_step stepclocks.
  // MMD sends 0xE7 04, whose quarter is 1 and whose dither row is all zeroes.
  reg [6:0] hclk_step_eff;
  always @(*) begin
    case (hclk_dither)
      2'd0:    hclk_step_eff = hclk_quarter;
      2'd1:    hclk_step_eff = hclk_quarter + ((hclk_phase == 3'd0) ? 7'd1 : 7'd0);
      2'd2:    hclk_step_eff = hclk_quarter + ((hclk_phase <= 3'd1) ? 7'd1 : 7'd0);
      default: hclk_step_eff = hclk_quarter + ((hclk_phase <= 3'd2) ? 7'd1 : 7'd0);
    endcase
  end

  // This cycle's response-queue producers. An ACK outranks a tick: if a command write lands on
  // the exact cycle a tick is due, the tick is dropped (the next one is a stepclock away).
  wire cmd_ack     = cmd_wr && (!uart_mode || (din == 8'hFF));
  wire hclk_tick_now = hclk_on && (hclk_sub + 20'd1 >= HCLK_STEP_CYCLES) &&
                                 (hclk_tick + 7'd1 >= hclk_step_eff);
  wire hclk_fire   = hclk_kick || hclk_tick_now;
  wire rq_push     = (cmd_ack || hclk_fire) && !rq_full;
  wire [7:0] rq_push_byte = cmd_ack ? 8'hFE : 8'hFD;   // MPUMSG_ACK / MPUMSG_HCLK

  assign dout = (addr == 16'hE0D2) ? {rq_empty, tx_busy_level, 6'b000000}
                                   : (rq_empty ? dat_latch : rq_head);
  assign irq  = !rq_empty;

  // ---- the line rate ---------------------------------------------------------------------
  // uart_tx_V2's own divider, fed from the same clock parameter the rest of this module uses,
  // so the baud is 31250 at every profile clock. 50/80/100/120 MHz all divide exactly.
  wire       line_tx;
  wire       line_busy;
  wire       line_wr = tx_go && !line_busy;
  uart_tx_V2 #(.clk_freq(SYS_CLOCK_HZ), .uart_freq(31250)) line (
      .clk(clk), .din(tx_byte), .wr_en(line_wr), .tx_busy(line_busy), .tx_p(line_tx)
  );
  assign uart_tx = line_tx;

  always @(posedge clk) begin
    if (reset) begin
      rq_wr <= 4'd0; rq_rd <= 4'd0; rq_cnt <= 5'd0;
      tx_wr <= 7'd0; tx_rd <= 7'd0; tx_cnt <= 7'd0;
      tx_go <= 1'b0; tx_byte <= 8'd0;
      phase <= PH_IDLE; uart_mode <= 1'b0; cmd_prev <= 8'h00;
      msg_status <= 8'd0; msg_pos <= 2'd0; msg_len <= 2'd0;
      snd_pos <= 2'd0; snd_len <= 2'd0; snd_on <= 1'b0;
      long_first <= 1'b1; long_head <= 8'd0; long_pos <= 11'd0;
      burst_on <= 1'b0; burst_ch <= 4'd0; burst_ph <= 2'd0;
      pend_valid <= 1'b0; pend_byte <= 8'd0;
      hclk_on <= 1'b0; hclk_sub <= 20'd0; hclk_tick <= 7'd0;
      hclk_quarter <= 7'd1; hclk_dither <= 2'd0; hclk_phase <= 3'd0; hclk_kick <= 1'b0;
      // mpu98ii_reset:1149 leaves the DATA register holding an ACK, which is the byte MMD's
      // presence probe reads at 0xE0D0 before it has asked for anything.
      dat_latch <= 8'hFE;
      // NEITHER FIFO ARRAY IS RESET, ON PURPOSE: a reset (or an init) on a RAM's contents makes
      // Quartus refuse the block RAM outright and build the whole array out of flops, which is
      // what this module's first priced shape did - 512 registers of MIDI-out queue and 789
      // registers in all, measured with tools/res_exp_map.py. Both arrays are written before
      // they are read (rq_head/tx_byte are only read when rq_cnt/tx_cnt say so), so an
      // undefined power-up image is unreachable.
      for (i = 0; i < 3; i = i + 1) begin
        msg_buf[i] <= 8'h00;
        snd_buf[i] <= 8'h00;
      end
    end
    else begin
      // ---- the response queue ----------------------------------------------------------
      // A DATA-port read pops; the byte it returns when empty is the latch, which this read
      // also refreshes (NP2kai i0, :1063-1071).
      if (dat_rd && !rq_empty) dat_latch <= rq_head;
      case ({rq_push, dat_rd && !rq_empty})
        2'b10: begin
          rq[rq_wr] <= rq_push_byte;
          rq_wr     <= rq_wr + 4'd1;
          rq_cnt    <= rq_cnt + 5'd1;
        end
        2'b01: begin
          rq_rd  <= rq_rd + 4'd1;
          rq_cnt <= rq_cnt - 5'd1;
        end
        2'b11: begin
          rq[rq_wr] <= rq_push_byte;
          rq_wr     <= rq_wr + 4'd1;
          rq_rd     <= rq_rd + 4'd1;
        end
        default: ;
      endcase

      // ---- the H.CLK tick --------------------------------------------------------------
      if (hclk_kick) hclk_kick <= 1'b0;
      if (hclk_on) begin
        // The first tick is queued in the cycle after 0x95 rather than one stepclock later.
        // THAT IS A DELIBERATE DEVIATION: MMD waits for the 0xFD inside a 4000-iteration
        // `out 0x5F` loop (CS:0x167E), and this core's wait port is the machine's own
        // measured 1621 ns (pc9821_iobus's IO_NS_5F_W / docs/probes/IO.TXT), so the
        // driver's window is comparable to the machine's
        // 3.5 ms here against 8-16 ms on the machine - while the stepclock is 5 ms. Leaving the
        // first tick to the period would make the driver's connection check a race against our
        // own bus speed. The PERIOD afterwards is the reference's rate.
        if (hclk_tick_now) begin
          hclk_sub   <= 20'd0;
          hclk_tick  <= 7'd0;
          hclk_phase <= hclk_phase + 3'd1;
        end
        else if (hclk_sub + 20'd1 >= HCLK_STEP_CYCLES) begin
          hclk_sub  <= 20'd0;
          hclk_tick <= hclk_tick + 7'd1;
        end
        else begin
          hclk_sub <= hclk_sub + 20'd1;
        end
      end
      else begin
        hclk_sub  <= 20'd0;
        hclk_tick <= 7'd0;
      end

      // ---- the 0xFF/0x3F all-notes-off run ----------------------------------------------
      // 16 x {0xB0+ch, 0x7B, 0x00} in channel order (sendmpureset, mpu98ii.c:223-233).
      if (burst_on && tx_push_burst) begin
        if (burst_ph == 2'd2) begin
          burst_ph <= 2'd0;
          if (burst_ch == 4'd15) burst_on <= 1'b0;
          else burst_ch <= burst_ch + 4'd1;
        end
        else begin
          burst_ph <= burst_ph + 2'd1;
        end
      end

      // ---- a completed short message on its way out -------------------------------------
      if (snd_on && tx_push_snd) begin
        if (snd_pos + 2'd1 >= snd_len) snd_on <= 1'b0;
        snd_pos <= snd_pos + 2'd1;
      end

      // ---- the MIDI-out queue and the transmitter --------------------------------------
      if (tx_push_pend) pend_valid <= 1'b0;
      case ({tx_push, tx_pop})
        2'b10: begin
          txq[tx_wr[4:0]] <= tx_push_byte;
          tx_wr      <= tx_wr + 7'd1;
          tx_cnt     <= tx_cnt + 7'd1;
        end
        2'b01: begin
          tx_byte <= txq[tx_rd[4:0]];
          tx_rd   <= tx_rd + 7'd1;
          tx_cnt  <= tx_cnt - 7'd1;
          tx_go   <= 1'b1;
        end
        2'b11: begin
          txq[tx_wr[4:0]] <= tx_push_byte;
          tx_wr      <= tx_wr + 7'd1;
          tx_byte    <= txq[tx_rd[4:0]];
          tx_rd      <= tx_rd + 7'd1;
          tx_go      <= 1'b1;
        end
        default: ;
      endcase
      if (tx_go && !line_busy && !tx_pop) tx_go <= 1'b0;

      // ---- a command write -------------------------------------------------------------
      if (cmd_wr) begin
        if (!uart_mode) begin
          // EVERY command is ACKed (ACK queued combinationally above), including the ones this
          // model does not implement: NP2kai's unknown-command row (mpucmd_xx, :396-401) still
          // returns through the ACK path, and MMD's resident-init ACK wait has NO timeout
          // (CS:0x01D3), so a missing ACK hangs the guest rather than failing it.
          cmd_prev <= din;
          phase    <= PH_IDLE;
          case (din)
            8'hFF: begin                      // reset (mpucmd_ff :607-614, sendmpureset :223)
              burst_on   <= 1'b1;
              burst_ch   <= 4'd0; burst_ph <= 2'd0;
              msg_status <= 8'd0; msg_pos <= 2'd0; msg_len <= 2'd0;
              snd_on     <= 1'b0; snd_pos <= 2'd0;
              long_first <= 1'b1; long_pos <= 11'd0;
              // setdefaultcondition (:131-170) clears flag2, so the reset stops the clock too.
              hclk_on    <= 1'b0; hclk_quarter <= 7'd1; hclk_dither <= 2'd0;
              hclk_phase <= 3'd0;
            end
            8'h3F: begin                      // UART mode (mpucmd_3f :451-457)
              uart_mode <= 1'b1;
              burst_on  <= 1'b1;              // sendmpureset is called here too
              burst_ch  <= 4'd0; burst_ph <= 2'd0;
            end
            8'h95: begin                      // clock to host ON (mpucmd_9x case 5, :532)
              hclk_on    <= 1'b1;
              hclk_sub   <= 20'd0;
              hclk_tick  <= 7'd0;
              hclk_phase <= 3'd0;
              hclk_kick  <= 1'b1;
            end
            8'h94: begin                      // clock to host OFF (mpucmd_9x case 4, :526)
              hclk_on <= 1'b0;
            end
            default: begin
              case (din[7:4])
                4'hD: begin                   // want to send data (ws :589, df :595)
                  phase      <= (din == 8'hDF) ? PH_LONG : PH_SHORT;
                  msg_pos    <= 2'd0;
                  long_first <= 1'b1;
                  long_pos   <= 11'd0;
                end
                4'hE: phase <= PH_FOLLOW;     // following byte (fo :601-605)
                default: ;                    // mode/timebase/flag groups: state only
              endcase
            end
          endcase
        end
        else if (din == 8'hFF) begin
          // UART mode's command port answers 0xFF (back to intelligent mode) and nothing else
          // (mpu98ii_o2's mode branch, :1039-1045).
          uart_mode <= 1'b0;
        end
      end

      // ---- a data write ----------------------------------------------------------------
      else if (dat_wr) begin
        if (uart_mode) begin
          // The dumb pipe: one data byte is one MIDI byte (mpu98ii_o0's mode branch, :1007).
          pend_valid <= 1'b1;
          pend_byte  <= din;
        end
        else begin
          case (phase)
            PH_FOLLOW: phase <= PH_IDLE;   // one follow byte (sendmpucmd, :860-877)
            PH_LONG: begin
              // Streamed: the byte ORDER a system message must preserve is the same either
              // way, and the real MPU's own UART forwards bytes as they arrive. NP2kai instead
              // holds the whole message in a 512-byte buffer and emits it only when it closes
              // (sendmpumsg :806-838); that buffer is the one thing this model does not spend.
              // The FRAMING is NP2kai's: a message starting 0xF0 closes at 0xF7, one starting
              // 0xF2/0xF3 closes at its third byte, anything else is a single byte, and the
              // 512-byte bound closes it too.
              pend_valid <= 1'b1;
              pend_byte  <= din;
              long_pos   <= long_pos + 11'd1;
              if (long_first) begin
                long_first <= 1'b0;
                long_head  <= din;
                if (!((din == 8'hF0) || (din == 8'hF2) || (din == 8'hF3))) phase <= PH_IDLE;
              end
              else if (((long_head == 8'hF0) && (din == 8'hF7)) ||
                       (((long_head == 8'hF2) || (long_head == 8'hF3)) &&
                        (long_pos >= 11'd2)) ||
                       (long_pos >= 11'd511)) begin
                phase <= PH_IDLE;
              end
            end
            PH_SHORT: begin
              if (msg_pos == 2'd0) begin
                if (d_is_status) begin
                  if (din[7:4] != 4'hF) msg_status <= din;
                  msg_buf[0] <= din;
                end
                else begin
                  msg_buf[0] <= msg_status;   // running status (sendmpumsg :779-783)
                  msg_buf[1] <= din;
                end
                msg_len <= d_len;             // the whole message's length (:100 table)
              end
              else begin
                msg_buf[msg_pos] <= din;
              end
              if (d_len == 2'd0) begin
                phase <= PH_IDLE;             // a length of zero sends nothing
              end
              else if (d_done) begin
                // Complete: hand the whole message over at once (sendmpushortmsg, :185-211).
                phase      <= PH_IDLE;
                snd_buf[0] <= mb0_next;
                snd_buf[1] <= mb1_next;
                snd_buf[2] <= mb2_next;
                snd_len    <= d_len;
                snd_pos    <= 2'd0;
                snd_on     <= 1'b1;
              end
              else begin
                msg_pos <= msg_pos + 2'd1;
              end
            end
            default: ;   // PH_IDLE: a stray data write sends nothing. NP2kai sets its write
                         // credit to 2049 here (sendmpudata :934-938), a 0.65 s BUSY; that is
                         // a modeling artifact of its host write path, not a card property.
          endcase
        end
      end

      // ---- a follow byte for 0xE0..0xEF (setmpucmdgroupe, :727-770) ---------------------
      if (dat_wr && !uart_mode && (phase == PH_FOLLOW) && (cmd_prev == 8'hE7)) begin
        hclk_quarter <= (din[7:2] == 6'd0) ? 7'd64 : {1'b0, din[7:2]};
        hclk_dither  <= din[1:0];
        hclk_sub     <= 20'd0;
        hclk_tick    <= 7'd0;
        hclk_phase   <= 3'd0;
      end
    end
  end

endmodule

`default_nettype wire
