`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_OPNA_WRQ:
// The PC-9801-86 command buffer (the WRQ in pc9821_opna) delivers its queued select/data writes to the vendored JT12 chip in guest order with every data write seeing its select latched first, captures a single worst-phase 1-clk fire into every operator register class (the pending latches persist and the sample-rate scan commits them, so no bus hold is needed), still lets jt12_kon sample a 0x28 key-on with the next write queued right behind it, reads 0x188 bit 7 clear at the first poll after a write (the real Xe10's XE10T /OPNA rows) and set only while the queue holds 64 words or more (half full), clearing once a word drains below that, gates 0x18C/0x18E writes away from the chip while the 0xA460 extension bit is clear, loses zero of 48 back-to-back no-poll writes across all 24 operator slots in both banks, answers a 0x18E read after a 0x18C select write with the select byte just written (NP2kai's opna_o18c s.data shadow) rather than the previous data byte, and pins the drop boundary at the reduced write cadence: a 160-write no-poll burst at 5 clk_sys per access overflows the 128-deep queue and loses writes, while the same burst behind the guest's WAITREADY poll loses none.
//
// The WRQ is probed against the vendored JT12 chip; the test sequence T0-T8:
//  T1  in-order delivery: queued select/data pairs reach the chip's own pins in the
//      guest's order, each data write seeing the chip's select latch set first.
//  T2  the capture question: the glue's comments and the WRQ commit say the vendored
//      FM register file "drops a write not held until its operator-scan slot", but the
//      drain presents each write for ONE clk (dr_fire) and then leaves the chip idle
//      for the whole gap. This test fires operator writes at the WORST scan phase
//      (the scan has just passed the target op, so the next visit is ~24 clk_en away,
//      far past the 1-clk fire) and checks the committed CSR fields. If the fields
//      commit anyway, capture is self-latching (jt12_mmr's up_opreg/op_din/up_op/up_ch
//      persist and the CSR commits at the next visit) and the "hold" story is wrong;
//      if they do not commit, the buffer silently loses writes depending on phase.
//  T3  the key-on race the queue closed: 0x28 (key-on) paced by DRAIN_GAP, with the
//      next data write queued right behind — jt12_kon must still sample it.
//  T4  overflow: a guest burst faster than the drain (no WAITREADY poll) fills the
//      128-deep queue; measure how many writes the chip never sees, and whether the
//      board's select shadow (sel_lo) then diverges from the chip's select latch.
//      The reference models (MAME pc9801_86.cpp, NP2kai board86.c) attach the
//      YM2608 to the ports with NO FIFO in front of it, so every write is latched
//      by the chip; the drop is a model-only divergence.
//  T5  BUSY semantics: 0x188 bit 7 is the queue's back-pressure only - clear at the
//      first poll after a write (the machine's XE10T /OPNA rows), set while the queue
//      is full, clear again once one word drains (the games' WAITREADY).
//  T6  0x18C readback contract: NP2kai's opna_o18c sets s.data, so a 0x18E read after
//      a 0x18C select answers the select byte; check what the board answers.
//  T7  extension gate: 0x18C/0x18E writes must not reach the chip while 0xA460 bit 0
//      is clear, and reads answer 0xFF.
//  T9  the reduced iobus write cadence (class 4 = 5 clk_sys per access,
//      the FSM floor): a 160-write no-poll burst overflows the 128-deep queue and loses
//      writes, while the same burst behind a WAITREADY poll loses none -- so the
//      drop is a function of the guest's handshake, not of the shortened wait.

module tb_pc9821_opna_wrq;
  reg clk = 0;
  always #5 clk = ~clk;   // 100 MHz, the project bench's system clock

  reg         reset = 1;
  reg  [15:0] io_addr = 0;
  reg         io_wr = 0;
  reg         io_rd = 0;
  reg  [7:0]  io_din = 0;
  wire [7:0]  io_dout;
  wire        io_rd_wait;
  wire        irq;
  wire signed [19:0] snd_l, snd_r;
  reg         extend = 0;
  reg  [5:0]  joystick = 6'b111111;
  reg         rhythm_we = 0;
  reg  [11:0] rhythm_waddr = 0;
  reg  [15:0] rhythm_wdata = 0;

  // ==== DUT ====
  // pc9821_opna wired as a bare board (no iobus): the WRQ, the drain engine and
  // the vendored JT12/JT49 chip behind the four ports, probed at its write pins.
  pc9821_opna #(.SYS_CLOCK_HZ(100_000_000)) u_dut (
    .clk(clk), .reset(reset),
    .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd), .io_din(io_din),
    .io_dout(io_dout), .io_rd_wait(io_rd_wait),
    .extend(extend), .joystick(joystick),
    .snd_l(snd_l), .snd_r(snd_r), .irq(irq),
    .rhythm_we(rhythm_we), .rhythm_waddr(rhythm_waddr), .rhythm_wdata(rhythm_wdata)
  );

  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_OPNA_WRQ: TIMEOUT");
  end

  // ------------------------------------------------------------------
  // Chip-level probes (the writes the YM2608 model itself latches).
  // ------------------------------------------------------------------
  wire        chip_write  = u_dut.u_opna.u_jt08.u_jt12.u_mmr.write;
  wire [7:0]  chip_din    = u_dut.u_opna.u_jt08.u_jt12.u_mmr.din;
  wire [1:0]  chip_addr   = u_dut.u_opna.u_jt08.u_jt12.u_mmr.addr;
  wire [7:0]  chip_selreg = u_dut.u_opna.u_jt08.u_jt12.u_mmr.selected_register;
  wire        chip_busy   = u_dut.u_opna.u_jt08.u_jt12.u_mmr.busy;
  wire        clk_en      = u_dut.u_opna.u_jt08.u_jt12.u_mmr.u_div.clk_en;
  wire [2:0]  cur_ch      = u_dut.u_opna.u_jt08.u_jt12.u_mmr.u_reg.cur_ch;
  wire [1:0]  cur_op      = u_dut.u_opna.u_jt08.u_jt12.u_mmr.u_reg.cur_op;
  // The CSR output fields the EG consumes for the CURRENT scan op (24 stages after
  // the load visit, so once steady they equal the last write to this op).
  wire [6:0]  o_tl        = u_dut.u_opna.u_jt08.u_jt12.u_mmr.u_reg.tl_IV;
  wire [2:0]  o_dt1       = u_dut.u_opna.u_jt08.u_jt12.u_mmr.u_reg.dt1_I;
  wire [3:0]  o_mul       = u_dut.u_opna.u_jt08.u_jt12.u_mmr.u_reg.mul_II;
  wire [1:0]  o_ks        = u_dut.u_opna.u_jt08.u_jt12.u_mmr.u_reg.ks_II;
  wire [4:0]  o_ar        = u_dut.u_opna.u_jt08.u_jt12.u_mmr.u_reg.ar_I;
  wire        o_amen      = u_dut.u_opna.u_jt08.u_jt12.u_mmr.u_reg.amsen_IV;
  wire [4:0]  o_dr        = u_dut.u_opna.u_jt08.u_jt12.u_mmr.u_reg.d1r_I;
  // Register 0x7x is the SUSTAIN rate: the CSR's [16:12] field feeds d2r_I.
  wire [4:0]  o_sr        = u_dut.u_opna.u_jt08.u_jt12.u_mmr.u_reg.d2r_I;
  wire [3:0]  o_sl        = u_dut.u_opna.u_jt08.u_jt12.u_mmr.u_reg.sl_I;
  wire [3:0]  o_rr        = u_dut.u_opna.u_jt08.u_jt12.u_mmr.u_reg.rr_I;
  wire [2:0]  o_ssgeg     = u_dut.u_opna.u_jt08.u_jt12.u_mmr.u_reg.ssg_eg_I;
  wire        o_ssge      = u_dut.u_opna.u_jt08.u_jt12.u_mmr.u_reg.ssg_en_I;
  wire        keyon_I     = u_dut.u_opna.u_jt08.u_jt12.u_mmr.u_reg.u_kon.keyon_I;

  // Debug: the CSR load path for the written op (ch0/op1 = req 00101).
  wire [6:0]  up_opreg    = u_dut.u_opna.u_jt08.u_jt12.u_mmr.up_opreg;
  wire [7:0]  mmr_op_din  = u_dut.u_opna.u_jt08.u_jt12.u_mmr.op_din;
  wire [1:0]  up_op       = u_dut.u_opna.u_jt08.u_jt12.u_mmr.up_op;
  wire [2:0]  up_ch       = u_dut.u_opna.u_jt08.u_jt12.u_mmr.up_ch;


  // Queue state.
  wire [7:0]  wrq_cnt  = u_dut.wrq_cnt;
  wire [1:0]  dr_state = u_dut.dr_state;
  wire [7:0]  dr_gap   = u_dut.dr_gap;
  wire        wrq_busy = (wrq_cnt != 0) | (dr_state != 2'd0);   // the drain, not the guest's BUSY

  // The chip-write log: every (addr, din) the chip's own write strobe presents.
  localparam int LOGMAX = 2048;
  reg [7:0]  log_din [0:LOGMAX-1];
  reg [1:0]  log_addr [0:LOGMAX-1];
  reg [7:0]  log_selreg [0:LOGMAX-1];   // the select latch DURING the write
  integer    log_n = 0;
  reg        keyon_pulse = 0;

  always @(posedge clk) begin
    if (chip_write && log_n < LOGMAX) begin
      log_din[log_n]    = chip_din;
      log_addr[log_n]   = chip_addr;
      log_selreg[log_n] = chip_selreg;
      log_n++;
    end
    if (keyon_I) keyon_pulse = 1;
  end

  // ------------------------------------------------------------------
  // Bus driver, shaped like pc9821_iobus: a one-cycle strobe, 186 clk per
  // access (io_access_cycles for this port class). Reads are answered one
  // cycle later (the S_DEVWAIT cycle the board's io_rd_wait buys).
  // drop_flag comes back as the push gate saw it: the wrq_cnt[7] value on the
  // strobe edge, i.e. 1 when the queue was full and the byte was swallowed.
  // ------------------------------------------------------------------
  task automatic bus_write(input [15:0] port, input [7:0] data, output reg drop_flag);
    begin
      io_addr <= port;
      io_din  <= data;
      drop_flag = 1'b0;
      @(posedge clk);
      io_wr <= 1'b1;
      drop_flag = wrq_cnt[7];
      @(posedge clk);
      io_wr <= 1'b0;
      for (int i = 0; i < 184; i++) @(posedge clk);
    end
  endtask

  task automatic bus_read(input [15:0] port, output [7:0] data);
    begin
      io_addr <= port;
      @(posedge clk);
      io_rd <= 1'b1;
      @(posedge clk);
      io_rd <= 1'b0;
      @(posedge clk);            // S_DEVWAIT: io_dout is valid this cycle
      data = io_dout;
      for (int i = 0; i < 184; i++) @(posedge clk);
    end
  endtask

  // A host write at the cadence the DW reduction produced: 5 clk_sys
  // strobe-to-strobe (pc9821_iobus IO_MIN_HOLD), in place of the 186 the
  // earlier class table charged. Same one-cycle strobe and same push-gate probe as
  // bus_write above, so T9 asks the drop question at the guest's new speed.
  task automatic bus_write_fast(input [15:0] port, input [7:0] data, output reg drop_flag);
    begin
      io_addr <= port;
      io_din  <= data;
      drop_flag = 1'b0;
      @(posedge clk);
      io_wr <= 1'b1;
      drop_flag = wrq_cnt[7];
      @(posedge clk);
      io_wr <= 1'b0;
      repeat (3) @(posedge clk);
    end
  endtask

  // The guest's WAITREADY at the same cadence: read 0x188 (the chip status with this
  // glue's wrq_busy folded into bit 7) until bit 7 is clear. busy_seen reports that at
  // least one poll found the queue non-empty.
  task automatic bus_waitready_fast(output reg busy_seen);
    reg [7:0] v;
    integer guard;
    begin
      busy_seen = 1'b0;
      guard = 0;
      v = 8'h80;
      while (v[7]) begin
        io_addr <= 16'h0188;
        @(posedge clk);
        io_rd <= 1'b1;
        @(posedge clk);
        io_rd <= 1'b0;
        @(posedge clk);
        v = io_dout;
        repeat (2) @(posedge clk);
        if (guard != 0) busy_seen = 1'b1;
        guard = guard + 1;
        if (guard > 100000) begin
          fail("WAITREADY never cleared");
          v = 8'h00;
        end
      end
    end
  endtask

  // Count the chip's clock enables (its own "time").
  task automatic wait_clk_en(input integer n);
    integer c;
    begin
      c = n;
      while (c > 0) begin
        @(posedge clk);
        if (clk_en) c--;
      end
    end
  endtask

  // Wait until the scan is at (op, ch) — one visit to the target.
  task automatic wait_scan(input [1:0] op, input [2:0] ch, input integer timeout_clk_en);
    integer c;
    begin
      c = timeout_clk_en;
      while (c > 0) begin
        @(posedge clk);
        if (cur_op === op && cur_ch === ch) return;
        if (clk_en) c--;
      end
      fail($sformatf("scan never reached op=%0d ch=%0d within %0d clk_en", op, ch, timeout_clk_en));
    end
  endtask

  // The worst phase for a write to (op, ch): the scan has JUST PASSED it, so the
  // next visit — the only visit the 1-clk fire could ever coincide with — is
  // ~24 clk_en away.
  task automatic wait_just_passed(input [1:0] op, input [2:0] ch);
    begin
      wait_scan(op, ch, 40);
      @(posedge clk);
      while (cur_op === op && cur_ch === ch) @(posedge clk);
    end
  endtask


  // Ring position: op*6 + channel index (ch 0,1,2,4,5,6 -> 0..5).
  function automatic integer pos_of(input [1:0] op, input [2:0] ch);
    begin
      case (ch)
        3'd0: pos_of = op * 6 + 0;
        3'd1: pos_of = op * 6 + 1;
        3'd2: pos_of = op * 6 + 2;
        3'd4: pos_of = op * 6 + 3;
        3'd5: pos_of = op * 6 + 4;
        default: pos_of = op * 6 + 5;
      endcase
    end
  endfunction

  // Smallest ring distance (either direction) from the current scan pos to (op,ch).
  function automatic integer dist_to(input [1:0] op, input [2:0] ch);
    integer d;
    begin
      d = pos_of(cur_op, cur_ch) - pos_of(op, ch);
      if (d < 0) d += 24;
      if (d > 12) d = 24 - d;
      dist_to = d;
    end
  endfunction

  // ==== CHECKS ====
  integer errors = 0;
  task automatic fail(input string msg);
    begin
      $display("WRQ-TB FAIL: %s", msg);
      errors++;
    end
  endtask

  task automatic note(input string msg);
    begin
      $display("WRQ-TB: %s", msg);
    end
  endtask

  // The queue empty and the drain idle, within a bounded time.
  task automatic wait_drain(input integer timeout_clk_en);
    integer c;
    begin
      c = timeout_clk_en;
      while (c > 0 && wrq_busy) begin
        @(posedge clk);
        if (clk_en) c--;
      end
      if (wrq_busy) fail($sformatf("queue still busy after %0d clk_en (cnt=%0d state=%0d gap=%0d)",
                                   timeout_clk_en, wrq_cnt, dr_state, dr_gap));
    end
  endtask

  reg [7:0] rd;
  reg       drop;

  initial begin
    $display("=== TB_PC9821_OPNA_WRQ: OPNA command buffer probe ===");
    reset = 1;
    repeat (20) @(posedge clk);
    reset = 0;
    // The chip's own reset is stretched 16 cen (~200 clk at 100 MHz); the
    // vendored core $finish'es on a write during it, and a real guest would
    // not write inside it either.
    repeat (300) @(posedge clk);

    // ----------------------------------------------------------------
    // T0: the board's readback contract is alive (chip ID, BUSY clear at idle).
    // ----------------------------------------------------------------
    bus_read(16'h0188, rd);
    if (rd[7]) fail("T0: 0x188 BUSY set at idle");
    bus_write(16'h0188, 8'hFF, drop);
    bus_read(16'h018A, rd);
    if (rd !== 8'h01) fail($sformatf("T0: chip ID: 0x18A read %02h, want 01", rd));
    wait_drain(400);
    log_n = 0;
    note("T0 pass: board readback alive, BUSY clear at idle");

    // ----------------------------------------------------------------
    // T1: in-order delivery to the chip's own pins.
    // Push six host writes; the chip must see the same six, in order, and
    // every data write must carry the select that preceded it.
    // ----------------------------------------------------------------
    bus_write(16'h0188, 8'h30, drop);   // 1
    bus_write(16'h018A, 8'hAA, drop);   // 2
    bus_write(16'h0188, 8'h31, drop);   // 3
    bus_write(16'h018A, 8'hBB, drop);   // 4
    bus_write(16'h0188, 8'h34, drop);   // 5
    bus_write(16'h018A, 8'hCC, drop);   // 6
    wait_drain(400);
    if (log_n !== 6) fail($sformatf("T1: chip saw %0d writes, want 6", log_n));
    else begin
      if (log_addr[0] !== 2'b00 || log_din[0] !== 8'h30) fail("T1: w1 not sel 0x30");
      if (log_addr[1] !== 2'b01 || log_din[1] !== 8'hAA || log_selreg[1] !== 8'h30)
        fail("T1: w2 not data AA on sel 0x30");
      if (log_addr[2] !== 2'b00 || log_din[2] !== 8'h31) fail("T1: w3 not sel 0x31");
      if (log_addr[3] !== 2'b01 || log_din[3] !== 8'hBB || log_selreg[3] !== 8'h31)
        fail("T1: w4 not data BB on sel 0x31");
      if (log_addr[4] !== 2'b00 || log_din[4] !== 8'h34) fail("T1: w5 not sel 0x34");
      if (log_addr[5] !== 2'b01 || log_din[5] !== 8'hCC || log_selreg[5] !== 8'h34)
        fail("T1: w6 not data CC on sel 0x34");
      if (errors === 0) note("T1 pass: six queued writes reached the chip in order, selects first");
    end
    log_n = 0;

    // ----------------------------------------------------------------
    // T2: the capture question, at the worst scan phase.
    // The drain fires each write for one clk; the scan then passes the target
    // op ~24 clk_en LATER. If the commit still lands, capture is
    // self-latching and the "hold until its slot" story in the glue is wrong.
    // ----------------------------------------------------------------
    begin : t2
      // The register encoding is [3:2]=op, [1:0]=ch (0x31 = S1 of ch 2 =
      // JT12 (op 0, ch 1); 0x34 = S3 of ch 1 = (op 1, ch 0)). The CSR
      // pipeline places each class's field a visit or two around the target
      // slot (class I at the slot, II one after, IV three after), so each
      // check sweeps a full ring cycle and passes if the written field value
      // appears within the class's window of the target slot.
      integer   misses;
      reg       seen;
      integer   w;

      // 0x31 @ (op0, ch1): DT1 is class I (loads at the target visit).
      wait_just_passed(2'd1, 3'd0);
      bus_write(16'h0188, 8'h31, drop);
      bus_write(16'h018A, 8'h2A, drop);   // dt1=010, mul=1010
      wait_clk_en(60);
      seen = 0;
      for (w = 0; w < 24 && !seen; w++) begin
        if (dist_to(2'd0, 3'd1) <= 2 && o_dt1 === 3'd2) seen = 1;
        wait_clk_en(1);
      end
      if (!seen) begin
        fail($sformatf("T2 0x31 DROPPED: dt1=%0d, 0x2A never appeared near (op0,ch1)", o_dt1));
        misses++;
      end

      // 0x34 @ (op1, ch0): DT1 is class I, MUL class II (0x34 is in the 0x30 block).
      wait_just_passed(2'd1, 3'd0);
      bus_write(16'h0188, 8'h34, drop);
      bus_write(16'h018A, 8'h45, drop);   // dt1=010, mul=0101
      wait_clk_en(60);
      seen = 0;
      for (w = 0; w < 24 && !seen; w++) begin
        if (dist_to(2'd1, 3'd0) <= 2 && (o_dt1 === 3'd2 || o_mul === 5'd5)) seen = 1;
        wait_clk_en(1);
      end
      if (!seen) begin
        fail($sformatf("T2 0x34 DROPPED: dt1/mul=%0d/%0d, 0x45 never appeared near (op1,ch0)", o_dt1, o_mul));
        misses++;
      end

      // 0x41 @ (op0, ch1): TL is class IV (loads three visits after the target).
      wait_just_passed(2'd1, 3'd0);
      bus_write(16'h0188, 8'h41, drop);
      bus_write(16'h018A, 8'hD5, drop);   // amen=1, tl=1010101
      wait_clk_en(60);
      seen = 0;
      for (w = 0; w < 24 && !seen; w++) begin
        if (dist_to(2'd0, 3'd1) <= 5 && o_tl === 7'b1010101) seen = 1;
        wait_clk_en(1);
      end
      if (!seen) begin
        fail($sformatf("T2 0x41 DROPPED: tl=%0d, 0xD5 never appeared near (op0,ch1)", o_tl));
        misses++;
      end

      // 0x51 @ (op0, ch1): AR is class I.
      wait_just_passed(2'd1, 3'd0);
      bus_write(16'h0188, 8'h51, drop);
      bus_write(16'h018A, 8'hC3, drop);   // ks=11, ar=00011
      wait_clk_en(60);
      seen = 0;
      for (w = 0; w < 24 && !seen; w++) begin
        if (dist_to(2'd0, 3'd1) <= 2 && o_ar === 5'd3) seen = 1;
        wait_clk_en(1);
      end
      if (!seen) begin
        fail($sformatf("T2 0x51 DROPPED: ar=%0d, 0xC3 never appeared near (op0,ch1)", o_ar));
        misses++;
      end

      // 0x71 @ (op0, ch1): SR (sustain rate -> d2r) is class I.
      wait_just_passed(2'd1, 3'd0);
      bus_write(16'h0188, 8'h71, drop);
      bus_write(16'h018A, 8'h19, drop);   // sr/d2r = 0x19[4:0] = 11001 = 25
      wait_clk_en(60);
      seen = 0;
      for (w = 0; w < 24 && !seen; w++) begin
        if (dist_to(2'd0, 3'd1) <= 2 && o_sr === 5'd25) seen = 1;
        wait_clk_en(1);
      end
      if (!seen) begin
        fail($sformatf("T2 0x71 DROPPED: sr/d2r=%0d (want 25), 0x19 never appeared near (op0,ch1)", o_sr));
        misses++;
      end

      // 0x91 @ (op0, ch1): SSG enable + SSG-EG[2:0], class I. din=1010.
      wait_just_passed(2'd1, 3'd0);
      bus_write(16'h0188, 8'h91, drop);
      bus_write(16'h018A, 8'h0A, drop);
      wait_clk_en(60);
      seen = 0;
      for (w = 0; w < 24 && !seen; w++) begin
        if (dist_to(2'd0, 3'd1) <= 2 && o_ssge === 1'b1 && o_ssgeg === 3'd2) seen = 1;
        wait_clk_en(1);
      end
      if (!seen) begin
        fail($sformatf("T2 0x91 DROPPED: ssg_en/eg=%0d/%0d, 0x0A never appeared near (op0,ch1)", o_ssge, o_ssgeg));
        misses++;
      end

      if (misses === 0)
        note("T2 pass: worst-phase 1-clk fires all committed -> capture is self-latching (no hold needed)");
      else
        note($sformatf("T2: %0d of 6 worst-phase operator writes LOST to the scan phase", misses));
        end
    log_n = 0;

    // ----------------------------------------------------------------
    // T3: the key-on race the queue closed: 0x28 paced, next data write right behind.
    // ----------------------------------------------------------------
    keyon_pulse = 0;
    bus_write(16'h0188, 8'h28, drop);
    bus_write(16'h018A, 8'hF0, drop);      // key on, ch0
    bus_write(16'h0188, 8'h27, drop);
    bus_write(16'h018A, 8'h00, drop);      // the next data write, not a key-on
    wait_drain(400);
    if (!keyon_pulse)
      fail("T3: keyon_I never pulsed - the key-on lost the race to the write behind it");
    else
      note("T3 pass: key-on sampled by the chip despite the write queued behind it");

    // ----------------------------------------------------------------
    // T4: overflow - a guest burst faster than the drain, no WAITREADY poll.
    // ----------------------------------------------------------------
    begin : t4
      integer pushed, dropped, delivered;
      integer i;
      integer k;
      reg [7:0] last_sel_pushed, last_data_pushed;
      reg [7:0] last_sel_delivered, last_data_delivered;

      log_n = 0;
      pushed = 0; dropped = 0;
      // 120 select/data pairs of stretched (0x3x) writes at the bus's fastest rate.
      for (i = 0; i < 120; i++) begin
        bus_write(16'h0188, 8'h30 + i[2:0], drop);
        if (drop) dropped++;
        pushed++;
        bus_write(16'h018A, 8'hA0 + i[2:0], drop);
        if (drop) dropped++;
        pushed++;
        last_sel_pushed  = 8'h30 + i[2:0];
        last_data_pushed = 8'hA0 + i[2:0];
      end
      wait_drain(20000);
      delivered = log_n;
      note($sformatf("T4: burst of %0d host writes: %0d dropped at the full queue, %0d delivered",
                    pushed, dropped, delivered));
      if (dropped === 0)
        fail("T4: expected the 128-deep queue to drop at least one burst write");
      if (delivered + dropped !== pushed)
        fail($sformatf("T4: accounting hole - %0d delivered + %0d dropped != %0d pushed",
                      delivered, dropped, pushed));

      // The chip must hold the LAST DELIVERED select; the guest's shadow holds
      // the last PUSHED one. Show the divergence the drop creates.
      for (k = log_n - 1; k >= 0; k--)
        if (log_addr[k] === 2'b01) break;
      last_data_delivered = log_din[k];
      last_sel_delivered  = log_selreg[k];   // the select latch during that data write
      if (last_sel_pushed !== last_sel_delivered)
        note($sformatf("T4: DIVERGENCE - chip last delivered sel/data=%02h/%02h, guest shadow keeps pushed sel/data=%02h/%02h",
                      last_sel_delivered, last_data_delivered, last_sel_pushed, last_data_pushed));
      else
        note($sformatf("T4: chip and shadow agree at %02h (no divergence this run)", last_sel_delivered));
      if (u_dut.sel_lo !== last_sel_pushed)
        note($sformatf("T4: sel_lo=%02h does not even track the pushed select %02h",
                      u_dut.sel_lo, last_sel_pushed));
    end

    // ----------------------------------------------------------------
    // T5: BUSY is the queue's own pacing only. The first poll after a write reads it
    // clear (docs/probes/XE10T-XE10.TXT /OPNA: `polls=1/1/..` on every row); it is set
    // while the queue holds 64 words or more (half full) and clears as soon as one word
    // drains below that (WAITREADY).
    // ----------------------------------------------------------------
    begin : t5
      integer busy_clk;
      integer poll_n;
      integer i;
      reg [7:0] v;
      wait_drain(20000);
      bus_write(16'h0188, 8'h40, drop);
      bus_write(16'h018A, 8'h55, drop);     // one stretched write
      bus_read(16'h0188, v);
      if (v[7]) fail("T5: BUSY set at the first poll after one FM data write (the machine reads it clear)");
      wait_drain(20000);
      // Fill the queue to half full with no poll (the class-4 cadence), then poll.
      for (i = 0; i < 100 && wrq_cnt < 64; i++) begin
        bus_write_fast(16'h0188, 8'h40, drop);
        if (drop) fail("T5: a write dropped before the queue was half full");
        if (wrq_cnt < 64) bus_write_fast(16'h018A, 8'h55, drop);
        if (drop) fail("T5: a write dropped before the queue was half full");
      end
      if (wrq_cnt < 64) fail($sformatf("T5: the queue holds %0d, the fill did not reach half full", wrq_cnt));
      busy_clk = 0;
      poll_n = 0;
      v = 8'h80;
      while (v[7] && busy_clk < 20000) begin
        io_addr <= 16'h0188;
        @(posedge clk);
        io_rd <= 1'b1;
        @(posedge clk);
        io_rd <= 1'b0;
        @(posedge clk);
        v = io_dout;
        poll_n++;
        busy_clk += 3;
      end
      if (busy_clk >= 20000)
        fail("T5: BUSY never cleared (WAITREADY would hang)");
      else if (wrq_cnt >= 64)
        fail("T5: BUSY read clear with the queue still half full");
      else if (poll_n < 2)
        fail("T5: BUSY read clear at the first poll with the queue half full (no pacing shown)");
      else
        note($sformatf("T5 pass: BUSY clear at the first poll after a write; with the queue half full it held %0d polls, until one word drained", poll_n));
      wait_drain(20000);
    end

    // ----------------------------------------------------------------
    // T6: 0x18C/0x18E readback against NP2kai's contract (opna_o18c sets s.data).
    // ----------------------------------------------------------------
    begin : t6
      extend = 1;
      repeat (10) @(posedge clk);
      bus_write(16'h0188, 8'h07, drop);
      bus_write(16'h018A, 8'h5A, drop);     // a known data byte in the shadow
      bus_write(16'h018C, 8'h10, drop);     // extended select, NOT 0x08/0x0F
      wait_drain(400);
      bus_read(16'h018E, rd);
      note($sformatf("T6: 0x18E read after 0x18C<-10h: board answered %02h", rd));
      if (rd === 8'h10)
        note("T6: matches NP2kai (opna_o18c sets s.data -> readback is the select byte)");
      else if (rd === 8'h5A)
        fail("T6: DIVERGES from NP2kai - 0x18C does not update the data shadow; 0x18E answers the stale 0x5A, NP2kai would answer 0x10");
      else
        fail($sformatf("T6: unexpected readback %02h", rd));
      extend = 0;
    end

    // ----------------------------------------------------------------
    // T7: extension gate - 0x18C/0x18E dead while 0xA460 bit 0 is clear.
    // ----------------------------------------------------------------
    begin : t7
      integer lg_before, lg_after;
      wait_drain(400);      // T6's queued writes are delivered before the gate test
      lg_before = log_n;
      extend = 0;
      repeat (10) @(posedge clk);
      bus_write(16'h018C, 8'h34, drop);
      bus_write(16'h018E, 8'h66, drop);
      wait_drain(400);
      lg_after = log_n;
      bus_read(16'h018C, rd);
      // B-4: the 0xA460 bit-0 drop (T6's extend 1->0) injects NP2kai's rhythm
      // key-off pair through the queue (select 0x10 then data 0xff; board86.c:79-94).
      // Those two words are legitimate; the 0x18C/0x18E writes above must be gated
      // (extend still clear) and add NOTHING beyond the injection.
      if (lg_after !== lg_before + 2)
        fail($sformatf("T7: chip saw %0d writes while the extension was closed, want the 2-word key-off injection", lg_after - lg_before));
      if (log_addr[lg_before] !== 2'b00 || log_din[lg_before] !== 8'h10)
        fail($sformatf("T7: injected word 0 = addr %0d din %02h, want select 0x10", log_addr[lg_before], log_din[lg_before]));
      if (log_addr[lg_before+1] !== 2'b01 || log_din[lg_before+1] !== 8'hFF)
        fail($sformatf("T7: injected word 1 = addr %0d din %02h, want data 0xff", log_addr[lg_before+1], log_din[lg_before+1]));
      if (rd !== 8'hFF) fail($sformatf("T7: 0x18C read %02h with extension closed, want FF", rd));
      bus_read(16'h018E, rd);
      if (rd !== 8'hFF) fail($sformatf("T7: 0x18E read %02h with extension closed, want FF", rd));
      note("T7 pass: extension gate holds writes/reads while closed (only the B-4 key-off injection reaches the chip)");
    end

    // ----------------------------------------------------------------
    // T8: back-to-back multi-operator burst - the clobber scenario the WRQ
    // exists to prevent. 24 distinct (ch,op) slots, each written sel+data
    // with NO WAITREADY between them (48 host writes; the queue peaks at
    // 48 < 128, so no overflow). A data fire lands >=216 cen after the
    // previous one while the 24-clk_en scan commits a pending write within
    // one ring, so no slot may hold a reset or foreign value afterwards.
    // ----------------------------------------------------------------
    begin : t8
      integer g, w, s, misses;
      reg [2:0] chv;
      reg [2:0] opv;      // 3 bits: the loop terminates at 4 (a 2-bit counter wraps!)
      reg [7:0] selreg, datav, rd8;
      reg [23:0] seen_d = 0;
      reg [23:0] seen_m = 0;
      reg [2:0]  CHV  [0:23];
      reg [1:0]  OPV  [0:23];
      reg [2:0]  EXPD [0:23];   // expected dt1 = op+1
      reg [3:0]  EXPM [0:23];   // expected mul = ch+1
      integer    busy_clk;

      extend = 1;
      repeat (10) @(posedge clk);
      for (g = 0; g < 6; g++) begin
        chv = (g < 3) ? g[2:0] : (g[2:0] + 3'd1);   // 0,1,2 base | 4,5,6 extended
        for (opv = 0; opv < 4; opv++) begin
          s = g * 4 + opv;
          CHV[s] = chv;
          OPV[s] = opv;
          EXPD[s] = opv + 3'd1;
          EXPM[s] = {1'b0, chv} + 4'd1;
          selreg = 8'h30 + 8'(opv * 4) + 8'(chv % 4);  // extended bank uses ch-4 == chv%4
          datav  = 8'(16 * (opv + 1) + (chv + 1));   // dt1[6:4]=op+1, mul[3:0]=ch+1
          bus_write(g < 3 ? 16'h0188 : 16'h018C, selreg, drop);
          bus_write(g < 3 ? 16'h018A : 16'h018E, datav,  drop);
          if (g == 2) begin
            // mid-burst: the queue holds ~18 of 128 entries, so the guest's WAITREADY
            // reads BUSY clear (the machine reads it clear after every write).
            bus_read(16'h0188, rd8);
            if (rd8[7])
              fail("T8: BUSY set mid-burst with the queue far from full");
          end
        end
      end
      // let the queue drain (BUSY no longer covers the drain, so it is read directly)
      busy_clk = 0;
      wait_drain(2000);
      // verify every slot: one full ring sweep, window +/-2 visits per slot.
      // dt1 (class I) and mul (class II) may skew a visit apart in the CSR
      // pipeline, so track them separately. 26 samples, not 24: the first wait
      // lands on the clk_en the sweep starts in, so 24 samples cover only 23 ring
      // positions and one slot's class-II field can fall outside the sweep.
      for (w = 0; w < 26; w++) begin
        for (s = 0; s < 24; s++) begin
          if (dist_to(OPV[s], CHV[s]) <= 2) begin
            if (o_dt1 === EXPD[s]) seen_d[s] = 1;
            if (o_mul === EXPM[s]) seen_m[s] = 1;
          end
        end
        wait_clk_en(1);
      end
      misses = 0;
      for (s = 0; s < 24; s++) begin
        if (!seen_d[s] || !seen_m[s]) begin
          misses++;
          $display("WRQ-TB: T8 slot op=%0d ch=%0d: exp dt1/mul=%0d/%0d saw_dt1=%b saw_mul=%b",
                   OPV[s], CHV[s], EXPD[s], EXPM[s], seen_d[s], seen_m[s]);
        end
      end
      if (misses === 0)
        note("T8 pass: 48 back-to-back writes to all 24 slots, zero lost to the pending-latch clobber");
      else
        fail($sformatf("T8: %0d of 24 slots wrong after the no-WAITREADY burst (clobber/loss)", misses));
    end

    // ----------------------------------------------------------------
    // T9: the reduced write cadence and the drop question.
    // The reduced iobus class lets the guest strobe a host write every 5 clk_sys
    // instead of 186; a stretched FM write drains over DRAIN_GAP=216 cen, so the
    // 128-deep queue can fill. Does the faster guest lose FM register writes, and
    // does the guest's WAITREADY poll cover it?
    //   (a) 80 select/data pairs with NO poll -> the queue fills and writes drop;
    //   (b) the same pairs WITH a WAITREADY poll before every write -> zero drops.
    // ----------------------------------------------------------------
    begin : t9
      integer i, dropped_np, dropped_p;
      integer pushed;
      reg busy_seen;

      // (a) no WAITREADY, the class-4 cadence.
      wait_drain(20000);
      log_n = 0; dropped_np = 0; pushed = 0;
      for (i = 0; i < 80; i++) begin
        bus_write_fast(16'h0188, 8'h30 + 8'(i % 64), drop);
        pushed = pushed + 1; if (drop) dropped_np = dropped_np + 1;
        bus_write_fast(16'h018A, 8'hA0 + 8'(i % 64), drop);
        pushed = pushed + 1; if (drop) dropped_np = dropped_np + 1;
      end
      wait_drain(20000);
      note($sformatf("T9a: class-4 no-poll burst: %0d host writes, %0d dropped at the full queue, %0d delivered",
                    pushed, dropped_np, log_n));
      if (dropped_np === 0)
        fail("T9a: expected the 128-deep queue to drop at least one class-4 no-poll burst write");

      // (b) the same burst behind the guest's WAITREADY, at the same cadence.
      wait_drain(20000);
      log_n = 0; dropped_p = 0; pushed = 0;
      for (i = 0; i < 80; i++) begin
        bus_waitready_fast(busy_seen);
        bus_write_fast(16'h0188, 8'h30 + 8'(i % 64), drop);
        pushed = pushed + 1; if (drop) dropped_p = dropped_p + 1;
        bus_waitready_fast(busy_seen);
        bus_write_fast(16'h018A, 8'hA0 + 8'(i % 64), drop);
        pushed = pushed + 1; if (drop) dropped_p = dropped_p + 1;
      end
      wait_drain(20000);
      if (dropped_p !== 0)
        fail($sformatf("T9b: a WAITREADY-polled class-4 burst dropped %0d of %0d writes", dropped_p, pushed));
      else
        note($sformatf("T9b: class-4 polled burst: 0 drops in %0d host writes (the guest's WAITREADY covers the reduced cadence)",
                      pushed));
    end

    // ==== VERDICT ====
    if (errors === 0) $display("TB_PC9821_OPNA_WRQ: PASS");
    else              $fatal(1, "TB_PC9821_OPNA_WRQ: FAIL (%0d errors)", errors);
    $finish;
  end

endmodule
