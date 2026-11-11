`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// Every rhythm write a BUSY-polling driver makes reaches the chip, at the bus's own rate and behind a loaded write queue: MDRV2 3.4F's rhythm set-up (Touhou 1's title music, 0x11 then the six instrument levels 0x18-0x1D written back to back) leaves each drum at the level and pan written to it, and two rhythm key-on writes (0x10) back to back start both drums, as NP2kai sound/rhythmc.c rhythm_setreg and ymfm adpcm_a_engine::write apply every write; the vendored rhythm unit holds one pending level and one pending key word and takes each only when its slot comes round, so the board's queue must not present the next one sooner.
//
// WHY. The vendored ADPCM-A unit keeps ONE pending instrument-level word (jt12_mmr
// `lracl <= din; up_lracl <= selected_register[2:0];`) that its gain ring copies into the
// channel's slot only when the ring reaches it (jt08_adpcm_gain `lracl2 <= up_ch_dec ==
// cur_ch ? lracl : lracl1;`, once per six 666 kHz enables, 9 us), and ONE pending key word
// (jt08_adpcm_drvA `if( up_aon ) aon_cmd_cpy <= aon_cmd;`) taken once per the same 9 us
// (`aon_sr <= ~{6{aon_cmd_cpy[7]}} & aon_cmd_cpy[5:0];` at cur_ch[5]). A second level
// (key) write inside that window replaces the first before its slot took it, and that
// drum keeps its old level (is never keyed). The chip covers this with its write busy
// (32 cycles after a data write, ymfm ym2608::write_data `ymfm_set_busy_end(32 *
// m_fm.clock_prescale())`); the board's queue hides the chip's BUSY from the guest
// (pc9821_opna.sv wrq_busy), so the queue's own drain gap after these writes has to.
//
// THE GUEST. MDRV2 3.4F (MDRV98.COM, Touhou 1's driver) writes a register as: poll 0x188
// until bit 7 is clear (0x20BC `in al,dx` / `shl al,1` / `jc`), `out` the select, a
// calibrated delay loop, `out` the data (0x1ED0-0x1EF1). Its title song's first tick
// writes 0x11 = 36 and then 0x18-0x1D = DF DE DF DA DF DD back to back (the driver's
// write stream as REIMU.MDT plays, logged by running MDRV98.COM under an x86 emulator).
//
// EXPECTED VALUES come from the references, not this RTL: NP2kai sound/rhythmc.c
// rhythm_setreg sets each track's flag and volume from every 0x18-0x1D write
// (`trk->flag = ((value & 0x80) >> 7) + ((value & 0x40) >> 5);`, `rhy->trkvol[reg - 0x18]
// = (UINT8)value;`) and starts every drum whose bit a 0x10 write sets with bit 7 clear;
// ymfm ymfm_adpcm.cpp adpcm_a_engine::write stores every register (`m_regs.write(regnum,
// data);`) and keys each channel a 0x00 (0x10 on the YM2608) write names. The internal taps
// only let the bench see the chip state those writes produce.

module tb_pc9821_opna_rhythm_level;
  localparam integer SYS_CLOCK_HZ = 50_000_000;
  reg clk = 0;
  always #10 clk = ~clk;

  reg        reset = 1;
  reg        extend = 1;
  reg [15:0] io_addr = 16'h0188;
  reg        io_wr = 0, io_rd = 0;
  reg  [7:0] io_din = 8'h00;
  wire [7:0] io_dout;
  wire       io_rd_wait, io_wr_wait, irq;
  wire signed [19:0] snd_l, snd_r;
  reg  [5:0] joystick = 6'b111111;

  // ==== DUT ====
  pc9821_opna #(.SYS_CLOCK_HZ(SYS_CLOCK_HZ)) dut (
    .clk(clk), .reset(reset),
    .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd),
    .io_din(io_din), .io_dout(io_dout),
    .io_rd_wait(io_rd_wait), .io_wr_wait(io_wr_wait),
    .extend(extend),
    .joystick(joystick),
    .snd_l(snd_l), .snd_r(snd_r),
    .irq(irq),
    .rhythm_we(1'b0), .rhythm_waddr(12'd0), .rhythm_wdata(16'd0)
  );

  // The rhythm unit's per-channel level ring and its key strobes, observed where the chip
  // keeps them.
  wire        g_cen    = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_gain.cen;
  wire [5:0]  g_cur    = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_gain.cur_ch;
  wire [7:0]  g_lracl2 = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.u_gain.lracl2;
  wire        a_cen6   = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.cen6;
  wire [5:0]  a_cur    = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.cur_ch;
  wire [5:0]  a_aon_sr = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.aon_sr;
  wire [7:0]  a_cmdcpy = dut.u_opna.u_jt08.u_jt12.gen_adpcm.u_adpcm_a.aon_cmd_cpy;
  wire [7:0]  wrq_cnt  = {1'b0, dut.wrq_cnt};

  // Each channel's level as the ring holds it: the step on which cur_ch names a drum
  // (re)loads that drum's slot into lracl2, so the edge after a step reads it there.
  reg  [7:0]  ring [0:5];
  reg         step_q = 1'b0;
  reg  [5:0]  cur_q  = 6'd0;
  integer     c;
  always @(posedge clk) begin
    if (step_q)
      for (c = 0; c < 6; c = c + 1)
        if (cur_q[c]) ring[c] <= g_lracl2;
    step_q <= g_cen;
    cur_q  <= g_cur;
  end

  // Every drum the chip keys on: the key word the unit takes at cur_ch[5] (bit 7 clear).
  reg  [5:0]  keyed = 6'd0;
  always @(posedge clk)
    if (a_cen6 && a_cur[5] && !a_cmdcpy[7]) keyed <= keyed | a_cmdcpy[5:0];

  integer errors = 0;
  integer n, k;

  // ==== CHECKS ====

  task automatic fail(input [8*120-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // One I/O access of the bus, then `gap` idle clocks (the guest's instruction time).
  integer gap = 0;
  task automatic bus_out(input [15:0] portnum, input [7:0] data);
    begin
      @(negedge clk); io_addr = portnum; io_din = data; io_wr = 1;
      @(negedge clk);
      while (io_wr_wait) @(negedge clk);   // the iobus holds a write the queue refuses
      io_wr = 0; io_din = 8'h00;
      repeat (gap) @(negedge clk);
    end
  endtask
  reg [7:0] st;
  task automatic bus_in(input [15:0] portnum);
    begin
      @(negedge clk); io_addr = portnum; io_rd = 1;
      @(posedge clk); #1 st = io_dout;
      @(negedge clk); io_rd = 0;
      repeat (gap) @(negedge clk);
    end
  endtask

  // MDRV2's register write: wait for BUSY clear, select, data.
  task automatic mdrv2_write(input [7:0] reg_index, input [7:0] data);
    begin
      n = 0;
      bus_in(16'h0188);
      while (st[7] && n < 100000) begin bus_in(16'h0188); n = n + 1; end
      if (n >= 100000) fail("BUSY never cleared");
      bus_out(16'h0188, reg_index);
      bus_out(16'h018A, data);
    end
  endtask

  task automatic wait_drain;
    begin
      n = 0;
      while ((wrq_cnt != 8'd0 || dut.dr_state != 2'd0) && n < 400000) begin
        @(posedge clk); n = n + 1;
      end
      if (n >= 400000) fail("the OPNA write queue never drained");
      repeat (2000) @(posedge clk);   // two full ring turns (9 us each = 450 clk)
    end
  endtask

  // A polling driver's FM stream ahead of the rhythm writes: the queue holds up to its
  // half-full BUSY point, so what follows drains at the queue's pace, not the guest's.
  task automatic fm_backlog(input integer words);
    begin
      for (k = 0; k < words; k = k + 1)
        mdrv2_write(8'h40 + (k % 4), 8'h7F);   // operator TL, silent values
    end
  endtask

  reg [7:0] lv [0:5];
  // `rev` writes 0x1D down to 0x18, so every level, not only the first five, is followed
  // by another one.
  task automatic level_setup(input [8*24-1:0] tag, input [7:0] base, input rev);
    begin
      lv[0] = 8'hDF ^ base; lv[1] = 8'hDE ^ base; lv[2] = 8'hDF ^ base;
      lv[3] = 8'hDA ^ base; lv[4] = 8'hDF ^ base; lv[5] = 8'hDD ^ base;
      mdrv2_write(8'h11, 8'h36);
      for (k = 0; k < 6; k = k + 1)
        if (rev) mdrv2_write(8'h1D - k[7:0], lv[5 - k]);
        else     mdrv2_write(8'h18 + k[7:0], lv[k]);
      wait_drain;
      for (k = 0; k < 6; k = k + 1)
        if (ring[k] !== lv[k]) begin
          $display("FAIL: %0s: drum %0d level/pan is %02x, written %02x @ %0t",
                   tag, k, ring[k], lv[k], $time);
          errors = errors + 1;
        end
    end
  endtask

  task automatic key_pair(input [8*24-1:0] tag);
    begin
      keyed = 6'd0;
      mdrv2_write(8'h10, 8'h01);   // bass drum on
      mdrv2_write(8'h10, 8'h08);   // hi-hat on
      wait_drain;
      if (keyed !== 6'b001001) begin
        $display("FAIL: %0s: the drums keyed on are %06b, the writes keyed 001001 @ %0t",
                 tag, keyed, $time);
        errors = errors + 1;
      end
      mdrv2_write(8'h10, 8'hBF);   // dump all
      wait_drain;
    end
  endtask

  // ==== STIMULUS ====
  initial begin
    for (c = 0; c < 6; c = c + 1) ring[c] = 8'hxx;
    repeat (40) @(posedge clk);
    @(negedge clk); reset = 0;
    repeat (2000) @(posedge clk);

    // ---- 1. the bus's own rate: the guest only waits for BUSY ----------------
    gap = 0;
    level_setup("bus rate", 8'h00, 1'b0);
    level_setup("bus rate, 1D first", 8'h03, 1'b1);
    key_pair("bus rate");

    // ---- 2. a guest instruction time between accesses (about 1 us) ------------
    gap = 50;
    level_setup("1 us accesses", 8'h01, 1'b0);
    key_pair("1 us accesses");

    // ---- 3. behind a polling driver's FM backlog ------------------------------
    gap = 0;
    fm_backlog(40);
    level_setup("behind an FM backlog", 8'h02, 1'b0);
    fm_backlog(40);
    key_pair("behind an FM backlog");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_OPNA_RHYTHM_LEVEL: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OPNA_RHYTHM_LEVEL: FAIL (%0d errors)", errors);
  end

  initial begin
    #900_000_000;
    $fatal(1, "TB_PC9821_OPNA_RHYTHM_LEVEL: TIMEOUT");
  end
endmodule
