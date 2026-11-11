`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_IRQ_SHARE: the PC-9801-86 board's INT5 line (IRQ12, the slave 8259's IR4) carries the OPNA's timer interrupt and the 86-PCM's buffer interrupt, and every OPNA timer event is its own request even while the 86-PCM holds the line: with 0xA468 = 0xA0 (the PCM interrupt enabled, the buffer empty - the state Metajo SP's PCML leaves after Riql's PCM driver) every Timer A overflow reaches the PIC and is answered with vector 0x14, as NP2kai raises each timer event itself (sound/opntimer.c fmport_a: `pic_setirq(opna->s.irq);`) and as the real PC-9821Xe10 behaves, which plays Metajo SP's timer-driven intro after Riql (docs/probes/KIT2-XE10-RUNLOG.TXT steps 06 and 07); a PCM event while the OPNA holds its flag is likewise a new request (sound/pcm86c.c pcm86_cb: `pic_setirq(pcm86->irq);`); an event from a low line reaches the PIC in the same cycle as before (no added latency); two events in one cycle are one request and an event hidden by the other source drops the line for exactly one cycle. FAIL-FIRST: with the two lines plainly ORed (the bench built with -DPRE_IRQ_SHARE, the system's wiring before the change) no Timer A overflow is delivered while the PCM line is high.
//
// ==== DUT ====
// The real pc9821_opna (ports 0x188/0x18A), the real pc9821_pcm86 (0xA468/0xA46A) on a small
// SDRAM model, pc9821_irq_share between them and the real pc9821_interrupts pair, wired as
// pc9821_system.sv wires them (the shared line on slave_irq bit 4). The CPU's acknowledge is
// the bench's inta_cycle: two INTA strobes, the cascade's.
//
// ==== CHECKS ====
// 1. The 86-PCM's interrupt enabled with an empty buffer holds the line; its own first edge is
//    one request and nothing more. 2. Four Timer A overflows under that held line: each reaches
//    the PIC within a few cycles and is answered with vector 0x14. 3. With the PCM line low an
//    OPNA event raises the shared line in its own cycle (no added latency). 4. The OPNA holding
//    its flag, a PCM event is a new request. 5. The junction alone, driven from the bench: two
//    rises in one cycle are one rise with no bubble; an event under the other source's level
//    drops the line for exactly one cycle; a rise in the cycle the other source falls is still
//    a fresh edge.
//
// ==== VERDICT ====
// PASS when every check holds; each failure is named; $fatal on any.
//
// ==== WHERE THE EXPECTATIONS COME FROM ====
// The machine: docs/probes/KIT2-XE10-RUNLOG.TXT runs step 06 (Riql) and then step 07 (Metajo SP)
// after a CONFIG reboot; the real Xe10's kit-2 video shows Metajo SP playing its intro to the
// title menu there (docs/user/compatibility.md's Metajo SP entry), so its FM driver's timer
// interrupts arrive although Riql left the 86-PCM's interrupt enabled with nothing to play.
// NP2kai's trace of the same sequence shows the state: Riql's last 0xA468 write is 0xB1 and
// PCML's read-modify-write leaves 0xB9, 0xA1, 0xA3; NP2kai delivers each OPNA timer event with
// its own pic_setirq (sound/opntimer.c fmport_a/fmport_b) and each 86-PCM event with its own
// (sound/pcm86c.c pcm86_cb), whatever the other source is doing.
module tb_pc9821_irq_share;

  localparam integer CLK_HZ = 50_000_000;
  reg clk = 0;
  always #10 clk = ~clk;          // 50 MHz

  reg reset = 1;

  // ---- the OPNA ----
  reg  [15:0] o_addr = 16'h0188;
  reg         o_wr = 0, o_rd = 0;
  reg  [7:0]  o_din = 8'h00;
  wire [7:0]  o_dout;
  wire        o_rd_wait;
  wire        opna_irq;
  wire signed [19:0] o_snd_l, o_snd_r;
  pc9821_opna #(.SYS_CLOCK_HZ(CLK_HZ)) opna (
    .clk(clk), .reset(reset),
    .io_addr(o_addr), .io_wr(o_wr), .io_rd(o_rd),
    .io_din(o_din), .io_dout(o_dout), .io_rd_wait(o_rd_wait),
    .extend(1'b0),
    .snd_l(o_snd_l), .snd_r(o_snd_r),
    .irq(opna_irq),
    .rhythm_we(1'b0), .rhythm_waddr(12'd0), .rhythm_wdata(16'd0)
  );

  // ---- the 86-PCM ----
  reg  [15:0] p_addr = 16'hA468;
  reg         p_wr = 0, p_rd = 0;
  reg  [7:0]  p_din = 8'h00;
  wire [7:0]  p_dout;
  wire        p_rd_wait, p_wr_wait;
  wire signed [15:0] p_snd_l, p_snd_r;
  wire        pcm86_irq;
  wire [15:0] p_dbg_count;
  wire        sdram_valid, sdram_ready, sdram_write, sdram_resp_valid;
  wire [31:0] sdram_addr, sdram_din, sdram_dout;
  wire  [3:0] sdram_be;
  wire  [7:0] sdram_burstcount;
  irq_share_sdram_model u_sdram (
    .clk(clk), .reset(reset),
    .valid(sdram_valid), .ready(sdram_ready), .write(sdram_write),
    .addr(sdram_addr), .din(sdram_din), .dout(sdram_dout),
    .resp_valid(sdram_resp_valid), .be(sdram_be)
  );
  pc9821_pcm86 #(.SYS_CLOCK_HZ(CLK_HZ)) pcm86 (
    .clk(clk), .reset(reset),
    .io_addr(p_addr), .io_wr(p_wr), .io_rd(p_rd), .io_din(p_din),
    .io_dout(p_dout), .io_rd_wait(p_rd_wait), .io_wr_wait(p_wr_wait),
    .snd_l(p_snd_l), .snd_r(p_snd_r),
    .irq(pcm86_irq),
    .dbg_count(p_dbg_count),
    .buf_base(32'd0),
    .sdram_valid(sdram_valid), .sdram_ready(sdram_ready), .sdram_write(sdram_write),
    .sdram_addr(sdram_addr), .sdram_din(sdram_din), .sdram_dout(sdram_dout),
    .sdram_resp_valid(sdram_resp_valid), .sdram_be(sdram_be),
    .sdram_burstcount(sdram_burstcount)
  );

  // ---- the shared line ----
  wire int5;
`ifdef PRE_IRQ_SHARE
  assign int5 = opna_irq | pcm86_irq;      // the system's wiring before the change
`else
  pc9821_irq_share share (
    .clk(clk), .reset(reset),
    .irq_a(opna_irq), .irq_b(pcm86_irq),
    .irq(int5)
  );
`endif

  // ---- the 8259 pair ----
  reg  [15:0] pic_addr = 16'h0000;
  reg         pic_wr = 0, pic_rd = 0;
  reg  [7:0]  pic_din = 8'h00;
  reg         pic_master_cs = 0, pic_slave_cs = 0;
  reg         pic_rst_n = 0;
  wire [7:0]  pic_slave_irq = {3'b000, int5, 4'b0000};
  wire        pic_cpu_intr;
  reg         pic_cpu_inta = 0;
  wire [31:0] pic_inta_din;
  wire        pic_inta_ready;
  wire [7:0]  pic_dout, pic_dbg_imr, pic_dbg_irr, pic_dbg_isr;
  wire        pic_pit_out0, pic_pit_out1, pic_pit_out2;
  pc9821_interrupts #(.SYS_CLOCK_HZ(CLK_HZ)) pic (
    .clk(clk), .reset_n(pic_rst_n),
    .io_wr(pic_wr), .io_rd(pic_rd), .io_addr(pic_addr), .io_din(pic_din),
    .master_cs(pic_master_cs), .slave_cs(pic_slave_cs), .pit_cs(1'b0),
    .io_dout(pic_dout),
    .keyboard_irq(1'b0), .vsync_irq(1'b0),
    .master_aux_irq(4'b0000),
    .slave_irq(pic_slave_irq),
    .cpu_intr(pic_cpu_intr), .cpu_inta(pic_cpu_inta),
    .cpu_inta_din(pic_inta_din), .cpu_inta_ready(pic_inta_ready),
    .pit_out0(pic_pit_out0), .pit_out1(pic_pit_out1), .pit_out2(pic_pit_out2),
    .dbg_imr(pic_dbg_imr), .dbg_irr(pic_dbg_irr), .dbg_isr(pic_dbg_isr)
  );

  // ---- a unit instance for the same-cycle cases, driven straight from the bench ----
  reg  ua = 0, ub = 0;
  wire uline;
`ifdef PRE_IRQ_SHARE
  assign uline = ua | ub;
`else
  pc9821_irq_share unit (.clk(clk), .reset(reset), .irq_a(ua), .irq_b(ub), .irq(uline));
`endif

  integer errors = 0;
  task automatic fail(input [8*120-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // OPNA register write through 0x188/0x18A (tb_pc9821_opna_timers' sound_o).
  task automatic sound_o(input [7:0] reg_index, input [7:0] data);
    begin
      @(negedge clk); o_addr = 16'h0188; o_din = reg_index; o_wr = 1;
      @(negedge clk);
      @(negedge clk); o_addr = 16'h018A; o_din = data;
      @(negedge clk);
      @(negedge clk); o_wr = 0; o_din = 8'h00;
      repeat (60) @(posedge clk);
    end
  endtask

  // 86-PCM register write: io_wr high across exactly one posedge.
  task automatic pcm_wr(input [15:0] portnum, input [7:0] data);
    begin
      @(negedge clk);
      p_addr = portnum; p_din = data; p_wr = 1'b1;
      @(posedge clk);
      #1 p_wr = 1'b0;
      @(negedge clk);
    end
  endtask

  task automatic pic_write(input [15:0] portnum, input [7:0] data);
    begin
      @(negedge clk);
      pic_addr = portnum;
      pic_master_cs = (portnum == 16'h0000) || (portnum == 16'h0002);
      pic_slave_cs  = (portnum == 16'h0008) || (portnum == 16'h000A);
      pic_din = data;
      pic_wr = 1;
      @(negedge clk);
      pic_wr = 0;
      pic_master_cs = 0; pic_slave_cs = 0;
    end
  endtask

  task automatic inta_cycle;
    begin
      @(negedge clk);
      pic_cpu_inta = 1;
      while (!pic_inta_ready) @(negedge clk);
      @(negedge clk);
      pic_cpu_inta = 0;
      repeat (2) @(negedge clk);
    end
  endtask

  // The guest's acknowledge of an INT5 interrupt: the two INTA cycles (the vector is the
  // second's), then a specific EOI to the slave (IR4) and to the master (IR7, the cascade).
  task automatic take_int5(input [8*60-1:0] what);
    begin
      inta_cycle();
      inta_cycle();
      if (pic_inta_din[7:0] !== 8'h14) begin
        $display("FAIL: %0s answered vector %02x, want 14 (slave IR4) @ %0t",
                 what, pic_inta_din[7:0], $time);
        errors = errors + 1;
      end
      pic_write(16'h0008, 8'h64);
      pic_write(16'h0000, 8'h67);
    end
  endtask

  // Wait for the PIC's INT, at most `limit` cycles; got = 1 if it came.
  task automatic wait_intr(input integer limit, output integer got);
    integer n;
    begin
      n = 0;
      while (!pic_cpu_intr && n < limit) begin @(posedge clk); n = n + 1; end
      got = pic_cpu_intr ? 1 : 0;
    end
  endtask

  integer got, k, delivered, n;
  reg seen_low;

  initial begin
    repeat (40) @(posedge clk);
    @(negedge clk); reset = 0;
    repeat (2000) @(posedge clk);

    // The PIC pair as the BIOS sets it: master ICW 11/08/80/1D, slave 11/10/07/01; only the
    // cascade (master IR7) and the slave's IR4 open.
    pic_rst_n = 1;
    repeat (4) @(posedge clk);
    pic_write(16'h0000, 8'h11); pic_write(16'h0002, 8'h08);
    pic_write(16'h0002, 8'h80); pic_write(16'h0002, 8'h1D);
    pic_write(16'h0002, 8'h7F);
    pic_write(16'h0008, 8'h11); pic_write(16'h000A, 8'h10);
    pic_write(16'h000A, 8'h07); pic_write(16'h000A, 8'h01);
    pic_write(16'h000A, 8'hEF);
    repeat (8) @(posedge clk);
    if (pic_cpu_intr) fail("INT was up before either source raised the line");

    // ---- 1. the 86-PCM holds the line: its interrupt enabled with the buffer empty ----
    // Riql's last control byte 0xB1 and PCML's read-modify-write leave bit 5 (the interrupt
    // enable) and bit 7 set with nothing written: 0xA8 resets the buffer, 0xA0 runs it.
    pcm_wr(16'hA468, 8'hA8);
    pcm_wr(16'hA468, 8'hA0);
    pcm_wr(16'hA46A, 8'h72);                 // the threshold PCML writes
    repeat (20) @(posedge clk);
    if (pcm86_irq !== 1'b1)
      fail("precondition: the 86-PCM line is not high with its interrupt enabled and the buffer empty");
    wait_intr(200, got);
    if (!got) fail("the 86-PCM's own rising edge was not requested");
    else take_int5("the 86-PCM's first request");
    repeat (20) @(posedge clk);
    if (pic_cpu_intr) fail("INT is up again with no new event (the held PCM line re-requested)");

    // ---- 2. OPNA Timer A overflows while the PCM line is held: each one is a request ----
    sound_o(8'h24, 8'hFF);                   // NA = 1023: one count, ~18 us
    sound_o(8'h25, 8'h03);
    sound_o(8'h27, 8'h15);                   // reset A's flag, enable its IRQ, start it
    delivered = 0;
    for (k = 0; k < 4; k = k + 1) begin
      n = 0;
      while (!opna_irq && n < 20000) begin @(posedge clk); n = n + 1; end
      if (!opna_irq) begin
        fail("Timer A did not overflow");
      end else begin
        wait_intr(8, got);                   // the event's edge plus the bubble: a few cycles
        if (got) begin
          delivered = delivered + 1;
          take_int5("a Timer A overflow under the held PCM line");
        end
        sound_o(8'h27, 8'h15);               // the driver's flag reset: the OPNA line falls
      end
    end
    if (delivered != 4) begin
      $display("FAIL: %0d of 4 Timer A overflows reached the PIC while the 86-PCM held the line @ %0t",
               delivered, $time);
      errors = errors + 1;
    end else
      $display("  4 of 4 Timer A overflows delivered under the held PCM line");

    // ---- 3. an event from a low line: the same cycle, no added latency ----
    sound_o(8'h27, 8'h10);                   // stop Timer A, reset its flag
    pcm_wr(16'hA468, 8'h80);                 // the PCM interrupt off: its line falls
    repeat (20) @(posedge clk);
    if (pcm86_irq !== 1'b0 || opna_irq !== 1'b0 || int5 !== 1'b0)
      fail("precondition: both lines and the shared line low");
    sound_o(8'h27, 8'h15);
    n = 0;
    while (!opna_irq && n < 20000) begin @(negedge clk); n = n + 1; end
    if (int5 !== 1'b1)
      fail("an OPNA event from a low line did not raise the shared line in the same cycle");
    wait_intr(8, got);
    if (!got) fail("an OPNA event from a low line was not requested");
    else take_int5("a Timer A overflow from a low line");

    // ---- 4. the OPNA holds its flag; a PCM event is its own request ----
    // Timer A's flag stays set (no reset); its request is taken and ended above. The PCM
    // interrupt enabled again with the buffer empty raises the PCM line: a new event.
    sound_o(8'h27, 8'h04);                   // stop counting, keep the IRQ enable: flag held
    repeat (20) @(posedge clk);
    if (opna_irq !== 1'b1) fail("precondition: the OPNA holds its line with its flag set");
    if (pic_cpu_intr) fail("INT is up with no new event (the held OPNA line re-requested)");
    pcm_wr(16'hA468, 8'hA0);
    repeat (2) @(posedge clk);
    if (pcm86_irq !== 1'b1) fail("precondition: the PCM line rose");
    wait_intr(8, got);
    if (!got) fail("a PCM event while the OPNA held the line was not requested");
    else take_int5("a PCM event under the held OPNA line");
    sound_o(8'h27, 8'h10);
    pcm_wr(16'hA468, 8'h80);

    // ---- 5. the unit's cycle shapes (SCED R4/R8: the colliding events fired together) ----
    // (a) both sources rise in one cycle from low: one rise, no bubble.
    // The sources change at a negedge; the PIC samples the line at the next posedge (the
    // event's cycle) and a bubble shows in the cycle after it.
    @(negedge clk); ua = 1; ub = 1;
    #1;
    if (uline !== 1'b1) fail("unit: two rises in one cycle did not raise the line at once");
    seen_low = 0;
    repeat (4) begin @(posedge clk); #1; if (uline !== 1'b1) seen_low = 1; end
    if (seen_low) fail("unit: two rises in one cycle dropped the line (one event, no bubble wanted)");
    @(negedge clk); ua = 0; ub = 0;
    repeat (3) @(posedge clk);
    // (b) b holds, a rises: the line drops for exactly one cycle, then is high.
    @(negedge clk); ub = 1;
    repeat (3) @(posedge clk);
    @(negedge clk); ua = 1;
    #1;
    if (uline !== 1'b1) fail("unit: the line fell in the event's own cycle");
    @(posedge clk); #1;
    if (uline !== 1'b0) fail("unit: an event hidden by the other source did not drop the line for a cycle");
    @(posedge clk); #1;
    if (uline !== 1'b1) fail("unit: the line did not come back the cycle after the bubble");
    seen_low = 0;
    repeat (4) begin @(posedge clk); #1; if (uline !== 1'b1) seen_low = 1; end
    if (seen_low) fail("unit: more than one bubble for one event");
    // (c) a rises in the same cycle b falls (b held the cycle before): still one bubble.
    @(negedge clk); ua = 0;
    repeat (3) @(posedge clk);
    @(negedge clk); ua = 1; ub = 0;
    @(posedge clk); #1;
    if (uline !== 1'b0) fail("unit: a rise as the other source fell made no fresh edge");
    @(posedge clk); #1;
    if (uline !== 1'b1) fail("unit: the line did not come back after the hand-over bubble");
    @(negedge clk); ua = 0;

    if (errors == 0) begin
      $display("TB_PC9821_IRQ_SHARE: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_IRQ_SHARE: FAIL (%0d errors)", errors);
  end

  initial begin
    #200_000_000;
    $fatal(1, "TB_PC9821_IRQ_SHARE: TIMEOUT");
  end

endmodule

// The 86-PCM's sample buffer side: a 32 KiB byte memory with a one-cycle accept and a
// two-cycle read (tb_pc9821_pcm86_irqmask's pcm86_sdram_model).
module irq_share_sdram_model (
  input  wire        clk, reset,
  input  wire        valid,
  output reg         ready,
  input  wire        write,
  input  wire [31:0] addr,
  input  wire [31:0] din,
  output reg  [31:0] dout,
  output reg         resp_valid,
  input  wire  [3:0] be
);
  reg [7:0]  mem [0:32767];
  reg [1:0]  st;
  reg [31:0] lat_addr;
  reg        lat_wr;
  integer    i;
  wire [14:0] wbase = {lat_addr[14:2], 2'b00};
  always @(posedge clk) begin
    ready      <= 1'b0;
    resp_valid <= 1'b0;
    if (reset) begin
      st <= 2'd0;
      for (i = 0; i < 32768; i = i + 1) mem[i] <= 8'h00;
    end else case (st)
      2'd0: if (valid) begin
              ready    <= 1'b1;
              lat_addr <= addr;
              lat_wr   <= write;
              st       <= 2'd1;
            end
      2'd1: begin
              if (lat_wr) begin
                if (be[0]) mem[wbase]     <= din[7:0];
                if (be[1]) mem[wbase + 1] <= din[15:8];
                if (be[2]) mem[wbase + 2] <= din[23:16];
                if (be[3]) mem[wbase + 3] <= din[31:24];
                st <= 2'd0;
              end else begin
                dout <= {mem[wbase + 3], mem[wbase + 2], mem[wbase + 1], mem[wbase]};
                st   <= 2'd2;
              end
            end
      default: begin
              resp_valid <= 1'b1;
              st         <= 2'd0;
            end
    endcase
  end
endmodule
