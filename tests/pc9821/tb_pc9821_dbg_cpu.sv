`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DBG_CPU: The CPU debug instrument (pc9821_dbg_cpu) puts out the record format tools/decode_dbglog.py reads, every record whole: the sampler's per-window counters sum to exactly the events driven (the event in the snapshot cycle included) with its flags, PIC and CS:EIP fields and a sequence number that gaps on a skipped sample; the memory snoop reports every CPU write and every read-response beat inside its window and none outside it (bursts, overlapping reads, a write and a beat in one cycle), and with the UART stalled and the queue overrun the delivered events plus the 0x32 LOST counts equal the events driven; the frozen trace fires on the PC, WRITE and RELOAD (zero-then-nonzero) triggers and on the second-stage window only after the first, honours the ARM_S delay and a POST count above 63, and dumps the last 2^TRACE_AW issues oldest first through several ring wraps followed by the trigger record; and a ring too small for the offered load drops whole records, never a part of one.
//
// WHY THIS EXISTS. The pn-stall instrument was built and fixed on hardware: an 8 KiB ring with an
// 11-bit drain index, a sample counter that lost the event of its own snapshot cycle, a post-trigger
// count too narrow for a longer window. Each is a width or an edge, invisible in the shape of
// the records and obvious in a count, which is how the checks below are written: every expected
// number is computed from the STIMULUS (the issues, writes and beats this bench drove), never from
// the DUT. Five DUTs share one bus; each is parameterised for the part it proves.

`default_nettype none

module tb_pc9821_dbg_cpu;
  // ==== DUT ====
  reg clk = 1'b0;
  always #5 clk = ~clk;

  // the shared bus
  reg [15:0] cpu_cs = 16'h0000;
  reg [31:0] cpu_eip = 32'h0;
  reg cpu_pe = 1'b0, cpu_vm = 1'b0, cpu_if = 1'b0, cpu_intr = 1'b0;
  reg [15:0] cpu_sp = 16'h0, cpu_flags = 16'h0;
  reg inta_ready = 1'b0;
  reg [7:0] inta_vec = 8'h00;
  reg vsync_irq = 1'b0, io_wr = 1'b0, io_rd = 1'b0;
  reg [15:0] io_addr = 16'h0;
  reg [7:0] imr = 8'h5A, irr = 8'h3C, isr = 8'h81, s_imr = 8'hE7, s_isr = 8'h18;
  reg ata_block_read = 1'b0, gate_read = 1'b0;
  reg [31:0] gate_addr = 32'h0;
  reg issue = 1'b0;
  reg [31:0] issue_eip = 32'h0;
  reg m_valid = 1'b0, m_ready = 1'b0, m_write = 1'b0, m_line = 1'b0, m_resp_valid = 1'b0;
  reg [31:0] m_addr = 32'h0, m_wdata = 32'h0, m_rdata = 32'h0;
  reg [3:0] m_be = 4'h0;
  reg [7:0] m_burst = 8'h0;

  localparam integer NI = 5;
  wire [NI-1:0] lw;
  wire [7:0]    lb [0:NI-1];
  reg  [NI-1:0] en = 5'b10111;         // the UART takes a byte (D's is held off until its overrun test)
  wire [NI-1:0] acc = lw & en;

  // A: sampler + snoop + RELOAD trigger with a second stage, a 16-entry trace (wraps)
  pc9821_dbg_cpu #(.LOG_CLK_HZ(100_000), .RING_AW(11), .SAMPLER_EN(1), .SAMPLE_MS(5), .SNOOP_EN(1),
      .SNOOP_LO(32'h0002_FA00), .SNOOP_HI(32'h0002_FC00), .TRIG_KIND(3), .TRIG_ADDR(32'h0002_FB20),
      .TRIG2_LO(32'h0003_D900), .TRIG2_HI(32'h0003_DA00), .ARM_S(0), .POST(32), .TRACE_AW(4))
    ua (.clk(clk), .cpu_cs(cpu_cs), .cpu_eip(cpu_eip), .cpu_pe(cpu_pe), .cpu_vm(cpu_vm), .cpu_if(cpu_if),
        .cpu_intr(cpu_intr), .cpu_sp(cpu_sp), .cpu_flags(cpu_flags), .inta_ready(inta_ready), .inta_vec(inta_vec),
        .vsync_irq(vsync_irq), .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .imr(imr), .irr(irr), .isr(isr),
        .s_imr(s_imr), .s_isr(s_isr), .ata_block_read(ata_block_read), .gate_read(gate_read), .gate_addr(gate_addr),
        .issue(issue), .issue_eip(issue_eip),
        .lio_stb(1'b0), .lio_wr(1'b0), .lio_addr(16'h0000), .lio_data(8'h00), .m_valid(m_valid), .m_ready(m_ready), .m_write(m_write),
        .m_addr(m_addr), .m_be(m_be), .m_burst(m_burst), .m_line(m_line), .m_wdata(m_wdata),
        .m_resp_valid(m_resp_valid), .m_rdata(m_rdata), .log_byte(lb[0]), .log_we(lw[0]), .log_accept(acc[0]));
  // B: the PC trigger, POST above 63, an 8-entry trace
  pc9821_dbg_cpu #(.LOG_CLK_HZ(10_000), .RING_AW(9), .SAMPLER_EN(0), .SNOOP_EN(0), .TRIG_KIND(1),
      .TRIG_CS(16'h1234), .TRIG_ADDR(32'h0000_5678), .ARM_S(0), .POST(100), .TRACE_AW(3))
    ub (.clk(clk), .cpu_cs(cpu_cs), .cpu_eip(cpu_eip), .cpu_pe(cpu_pe), .cpu_vm(cpu_vm), .cpu_if(cpu_if),
        .cpu_intr(cpu_intr), .cpu_sp(cpu_sp), .cpu_flags(cpu_flags), .inta_ready(inta_ready), .inta_vec(inta_vec),
        .vsync_irq(vsync_irq), .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .imr(imr), .irr(irr), .isr(isr),
        .s_imr(s_imr), .s_isr(s_isr), .ata_block_read(ata_block_read), .gate_read(gate_read), .gate_addr(gate_addr),
        .issue(issue), .issue_eip(issue_eip),
        .lio_stb(1'b0), .lio_wr(1'b0), .lio_addr(16'h0000), .lio_data(8'h00), .m_valid(m_valid), .m_ready(m_ready), .m_write(m_write),
        .m_addr(m_addr), .m_be(m_be), .m_burst(m_burst), .m_line(m_line), .m_wdata(m_wdata),
        .m_resp_valid(m_resp_valid), .m_rdata(m_rdata), .log_byte(lb[1]), .log_we(lw[1]), .log_accept(acc[1]));
  // C: the WRITE trigger behind a one-second ARM delay, POST = 0
  pc9821_dbg_cpu #(.LOG_CLK_HZ(10_000), .RING_AW(9), .SAMPLER_EN(0), .SNOOP_EN(0), .TRIG_KIND(2),
      .TRIG_ADDR(32'h0000_1002), .ARM_S(1), .POST(0), .TRACE_AW(3))
    uc (.clk(clk), .cpu_cs(cpu_cs), .cpu_eip(cpu_eip), .cpu_pe(cpu_pe), .cpu_vm(cpu_vm), .cpu_if(cpu_if),
        .cpu_intr(cpu_intr), .cpu_sp(cpu_sp), .cpu_flags(cpu_flags), .inta_ready(inta_ready), .inta_vec(inta_vec),
        .vsync_irq(vsync_irq), .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .imr(imr), .irr(irr), .isr(isr),
        .s_imr(s_imr), .s_isr(s_isr), .ata_block_read(ata_block_read), .gate_read(gate_read), .gate_addr(gate_addr),
        .issue(issue), .issue_eip(issue_eip),
        .lio_stb(1'b0), .lio_wr(1'b0), .lio_addr(16'h0000), .lio_data(8'h00), .m_valid(m_valid), .m_ready(m_ready), .m_write(m_write),
        .m_addr(m_addr), .m_be(m_be), .m_burst(m_burst), .m_line(m_line), .m_wdata(m_wdata),
        .m_resp_valid(m_resp_valid), .m_rdata(m_rdata), .log_byte(lb[2]), .log_we(lw[2]), .log_accept(acc[2]));
  // D: a ring far too small for the offered load: 128 bytes, a 1 ms (10-clock) sampler, a snoop
  pc9821_dbg_cpu #(.LOG_CLK_HZ(10_000), .RING_AW(7), .SAMPLER_EN(1), .SAMPLE_MS(1), .SNOOP_EN(1),
      .SNOOP_LO(32'h0000_8000), .SNOOP_HI(32'h0000_9000), .TRIG_KIND(0))
    ud (.clk(clk), .cpu_cs(cpu_cs), .cpu_eip(cpu_eip), .cpu_pe(cpu_pe), .cpu_vm(cpu_vm), .cpu_if(cpu_if),
        .cpu_intr(cpu_intr), .cpu_sp(cpu_sp), .cpu_flags(cpu_flags), .inta_ready(inta_ready), .inta_vec(inta_vec),
        .vsync_irq(vsync_irq), .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .imr(imr), .irr(irr), .isr(isr),
        .s_imr(s_imr), .s_isr(s_isr), .ata_block_read(ata_block_read), .gate_read(gate_read), .gate_addr(gate_addr),
        .issue(issue), .issue_eip(issue_eip),
        .lio_stb(1'b0), .lio_wr(1'b0), .lio_addr(16'h0000), .lio_data(8'h00), .m_valid(m_valid), .m_ready(m_ready), .m_write(m_write),
        .m_addr(m_addr), .m_be(m_be), .m_burst(m_burst), .m_line(m_line), .m_wdata(m_wdata),
        .m_resp_valid(m_resp_valid), .m_rdata(m_rdata), .log_byte(lb[3]), .log_we(lw[3]), .log_accept(acc[3]));
  // E: a long sampler window (10,000 clocks) for the INTR-high counter
  pc9821_dbg_cpu #(.LOG_CLK_HZ(100_000), .RING_AW(9), .SAMPLER_EN(1), .SAMPLE_MS(100), .SNOOP_EN(0), .TRIG_KIND(0))
    ue (.clk(clk), .cpu_cs(cpu_cs), .cpu_eip(cpu_eip), .cpu_pe(cpu_pe), .cpu_vm(cpu_vm), .cpu_if(cpu_if),
        .cpu_intr(cpu_intr), .cpu_sp(cpu_sp), .cpu_flags(cpu_flags), .inta_ready(inta_ready), .inta_vec(inta_vec),
        .vsync_irq(vsync_irq), .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .imr(imr), .irr(irr), .isr(isr),
        .s_imr(s_imr), .s_isr(s_isr), .ata_block_read(ata_block_read), .gate_read(gate_read), .gate_addr(gate_addr),
        .issue(issue), .issue_eip(issue_eip),
        .lio_stb(1'b0), .lio_wr(1'b0), .lio_addr(16'h0000), .lio_data(8'h00), .m_valid(m_valid), .m_ready(m_ready), .m_write(m_write),
        .m_addr(m_addr), .m_be(m_be), .m_burst(m_burst), .m_line(m_line), .m_wdata(m_wdata),
        .m_resp_valid(m_resp_valid), .m_rdata(m_rdata), .log_byte(lb[4]), .log_we(lw[4]), .log_accept(acc[4]));

  // ==== STIMULUS ====
  reg [31:0] lfsr = 32'hD00DF00D;
  function automatic [31:0] rnd();
    begin
      lfsr = lfsr ^ (lfsr << 13); lfsr = lfsr ^ (lfsr >> 17); lfsr = lfsr ^ (lfsr << 5);
      rnd = lfsr;
    end
  endfunction
  integer errors = 0;
  task automatic fail(input string m);
    begin if (errors < 30) $display("FAIL: %0s", m); errors = errors + 1; end
  endtask

  // the capture: every accepted byte of each DUT
  localparam integer CAPN = 40000;
  reg [7:0] cap [0:NI-1][0:CAPN-1];
  integer   ncap [0:NI-1];
  integer   ci;
  initial for (ci = 0; ci < NI; ci = ci + 1) ncap[ci] = 0;
  always @(posedge clk) for (ci = 0; ci < NI; ci = ci + 1) if (acc[ci] && ncap[ci] < CAPN) begin
    cap[ci][ncap[ci]] = lb[ci];
    ncap[ci] = ncap[ci] + 1;
  end

  // the bench's own record-length table (from the record definitions in pc9821_dbg_cpu's header)
  function automatic integer tlen(input [7:0] t);
    case (t)
      8'h20, 8'h21: tlen = 34;
      8'h30, 8'h31: tlen = 15;
      8'h32: tlen = 8;
      8'h43: tlen = 15;
      8'h44: tlen = 13;
      default: tlen = 0;
    endcase
  endfunction

  // Walk a capture: every record must start with A5, have a known type, fit, and carry its tail.
  integer rec_off [0:NI-1][0:3999];
  integer nrec [0:NI-1];
  task automatic parse(input integer d);
    integer i, l;
    begin
      i = 0; nrec[d] = 0;
      while (i < ncap[d]) begin
        l = (cap[d][i] == 8'hA5) ? tlen(cap[d][i+1]) : 0;
        if (l == 0) begin fail($sformatf("dut %0d: byte %0d is not a record start (%02x %02x)", d, i, cap[d][i], cap[d][i+1])); i = ncap[d]; end
        else if (i + l > ncap[d]) i = ncap[d];   // the record still being drained at the end of the capture
        else begin
          if ((cap[d][i+1] == 8'h20 || cap[d][i+1] == 8'h21 || cap[d][i+1] == 8'h43 || cap[d][i+1] == 8'h44) && cap[d][i+l-1] != 8'h5A)
            fail($sformatf("dut %0d: record at %0d (%02x) lacks its 0x5A tail", d, i, cap[d][i+1]));
          if (nrec[d] < 4000) rec_off[d][nrec[d]] = i;
          nrec[d] = nrec[d] + 1;
          i = i + l;
        end
      end
    end
  endtask
  function automatic [31:0] f32(input integer d, input integer o);
    f32 = {cap[d][o], cap[d][o+1], cap[d][o+2], cap[d][o+3]};
  endfunction
  function automatic [15:0] f16(input integer d, input integer o);
    f16 = {cap[d][o], cap[d][o+1]};
  endfunction

  // bus tasks, all driven at the falling edge for one cycle
  task automatic idle_bus();
    begin
      m_valid = 1'b0; m_ready = 1'b0; m_write = 1'b0; m_resp_valid = 1'b0; issue = 1'b0;
      inta_ready = 1'b0; vsync_irq = 1'b0; io_wr = 1'b0; io_rd = 1'b0; ata_block_read = 1'b0; gate_read = 1'b0;
    end
  endtask
  task automatic tick(input integer n);
    begin repeat (n) begin @(negedge clk); idle_bus(); end end
  endtask
  task automatic bus_write(input [31:0] a, input [3:0] be, input [31:0] d);
    begin
      @(negedge clk); idle_bus();
      m_valid = 1'b1; m_ready = 1'b1; m_write = 1'b1; m_addr = a; m_be = be; m_wdata = d;
      note_write(a, be, d);
    end
  endtask
  integer iss_n = 0;                    // issues driven so far
  task automatic do_issue(input [15:0] cs, input [31:0] eip);
    begin
      @(negedge clk); idle_bus();
      issue = 1'b1; issue_eip = eip; cpu_cs = cs; cpu_sp = iss_n[15:0] ^ 16'h5A5A; cpu_flags = iss_n[15:0] + 16'h0202;
      iss_n = iss_n + 1;
    end
  endtask

  // ---- the expected snoop events (DUTs A and D differ in their windows) ----
  function automatic inwin(input integer d, input [31:0] a);
    inwin = (d == 0) ? (a >= 32'h0002_FA00 && a < 32'h0002_FC00) : (a >= 32'h0000_8000 && a < 32'h0000_9000);
  endfunction
  localparam integer MAXEV = 12000;
  reg        xe_read [0:1][0:MAXEV-1];
  reg [31:0] xe_addr [0:1][0:MAXEV-1];
  reg [31:0] xe_data [0:1][0:MAXEV-1];
  reg [3:0]  xe_aux  [0:1][0:MAXEV-1];
  integer    nxe [0:1];
  initial begin nxe[0] = 0; nxe[1] = 0; end
  task automatic note_event(input integer w, input r, input [31:0] a, input [3:0] aux, input [31:0] d);
    begin
      if (inwin(w == 0 ? 0 : 3, a) && nxe[w] < MAXEV) begin
        xe_read[w][nxe[w]] = r; xe_addr[w][nxe[w]] = a; xe_data[w][nxe[w]] = d; xe_aux[w][nxe[w]] = aux;
        nxe[w] = nxe[w] + 1;
      end
    end
  endtask
  task automatic note_write(input [31:0] a, input [3:0] be, input [31:0] d);
    begin note_event(0, 1'b0, a, be, d); note_event(1, 1'b0, a, be, d); end
  endtask

  // reads: a request queue in the bench; a response beat per call
  reg [31:0] rq_a [0:63];
  reg [7:0]  rq_n [0:63];
  reg        rq_l [0:63];
  reg [2:0]  rq_b [0:63];
  integer    rq_w = 0, rq_r = 0, rq_beat = 0;
  function automatic [31:0] rdata_of(input [31:0] a);
    rdata_of = (a * 32'h9E3779B1) ^ 32'hA5A5_0001;
  endfunction
  task automatic read_req(input [31:0] a, input [7:0] n, input line);
    begin
      @(negedge clk); idle_bus();
      m_valid = 1'b1; m_ready = 1'b1; m_write = 1'b0; m_addr = a; m_burst = n; m_line = line;
      rq_a[rq_w % 64] = a; rq_n[rq_w % 64] = (n == 8'd0) ? 8'd1 : n; rq_l[rq_w % 64] = line; rq_b[rq_w % 64] = n[2:0];
      rq_w = rq_w + 1;
    end
  endtask
  // one response beat; `with_write` drives an accepted write in the same cycle
  task automatic read_beat(input with_write, input [31:0] wa, input [31:0] wd);
    reg [31:0] ba;
    begin
      @(negedge clk); idle_bus();
      ba = rq_a[rq_r % 64] + 32'd4 * rq_beat;
      m_resp_valid = 1'b1; m_rdata = rdata_of(ba);
      note_event(0, 1'b1, ba, {rq_l[rq_r % 64], rq_b[rq_r % 64]}, rdata_of(ba));
      note_event(1, 1'b1, ba, {rq_l[rq_r % 64], rq_b[rq_r % 64]}, rdata_of(ba));
      if (with_write) begin
        m_valid = 1'b1; m_ready = 1'b1; m_write = 1'b1; m_addr = wa; m_be = 4'hF; m_wdata = wd;
        note_write(wa, 4'hF, wd);
      end
      rq_beat = rq_beat + 1;
      if (rq_beat == rq_n[rq_r % 64]) begin rq_beat = 0; rq_r = rq_r + 1; end
    end
  endtask

  // ==== CHECKS ====
  integer n, i, j, k, b, t0, ev0, dump_fd;
  reg [8*256-1:0] dump_name;
  integer sum [0:12];
  integer d, o, nsmp, nlow, seqprev, seqoff, gaps, found, nev, lostsum, evdelivered, rep;
  reg [31:0] cyc_prev;
  reg [7:0] seq;
  initial begin
    idle_bus();
    repeat (6) @(negedge clk);

    // ---- 0. the ARM delay (DUT C): a covering write inside the first second is ignored ----
    iss_n = 0;
    for (k = 0; k < 20; k = k + 1) do_issue(16'h0200, 32'h9000 + k);
    bus_write(32'h0000_1000, 4'h4, 32'h1111_1111);
    tick(100);
    if (ncap[2] != 0) fail("the WRITE trigger fired before ARM_S seconds");

    // ---- 1. the sampler (DUTs A and E): counters sum to the events driven ----
    cpu_pe = 1'b1; cpu_vm = 1'b0; cpu_if = 1'b1; cpu_intr = 1'b0; cpu_cs = 16'hF800; cpu_eip = 32'h0000_1234;
    for (i = 0; i < 13; i = i + 1) sum[i] = 0;
    for (n = 0; n < 30000; n = n + 1) begin
      @(negedge clk); idle_bus();
      case (rnd() % 40)
        0: begin inta_ready = 1'b1; inta_vec = 8'h08; sum[0] = sum[0] + 1; end
        1: begin inta_ready = 1'b1; inta_vec = 8'h09; sum[1] = sum[1] + 1; end
        2: begin inta_ready = 1'b1; inta_vec = 8'h0A; sum[2] = sum[2] + 1; end
        3: begin inta_ready = 1'b1; inta_vec = 8'h0B + (rnd() % 5); sum[3] = sum[3] + 1; end
        4: begin inta_ready = 1'b1; inta_vec = 8'h11; sum[4] = sum[4] + 1; end
        5: begin inta_ready = 1'b1; inta_vec = 8'h15; sum[5] = sum[5] + 1; end
        6: begin
             inta_ready = 1'b1;
             case (rnd() % 5) 0: inta_vec = 8'h10; 1: inta_vec = 8'h12; 2: inta_vec = 8'h13; 3: inta_vec = 8'h16; default: inta_vec = 8'h17; endcase
             sum[6] = sum[6] + 1;
           end
        7: begin inta_ready = 1'b1; inta_vec = 8'h14; sum[12] = sum[12] + 1; end
        8: begin inta_ready = 1'b1; inta_vec = 8'h00; end                                  // vector 0 is not an ack
        9: begin inta_ready = 1'b0; inta_vec = 8'h08; end                                  // not ready: not an ack
        10: begin vsync_irq = 1'b1; sum[7] = sum[7] + 1; end
        11: begin io_wr = 1'b1; io_addr = 16'h0064; sum[8] = sum[8] + 1; end
        12: begin io_wr = 1'b1; io_addr = 16'h0066; end
        13: begin ata_block_read = 1'b1; sum[9] = sum[9] + 1; end
        14: begin io_rd = 1'b1; io_addr = 16'h00A0; sum[10] = sum[10] + 1; end
        15: begin io_rd = 1'b1; io_addr = 16'h00A2; end
        16: begin gate_read = 1'b1; gate_addr = 32'h0000_0030 + 32'h1000 * (rnd() % 4); sum[11] = sum[11] + 1; end
        17: begin gate_read = 1'b1; gate_addr = 32'h0000_0018; sum[11] = sum[11] + 1; end
        18: begin gate_read = 1'b1; gate_addr = 32'h0000_0040; end
        default: ;
      endcase
    end
    tick(1500);                                       // two quiet windows: the last snapshot takes the tail
    parse(0);
    begin : smp
      integer tot [0:12];
      integer rr;
      for (i = 0; i < 13; i = i + 1) tot[i] = 0;
      nsmp = 0; seqprev = -1; gaps = 0;
      for (rr = 0; rr < nrec[0]; rr = rr + 1) begin
        o = rec_off[0][rr];
        if (cap[0][o+1] == 8'h20 || cap[0][o+1] == 8'h21) begin
          nsmp = nsmp + 1;
          tot[0] = tot[0] + cap[0][o+8];   tot[1] = tot[1] + cap[0][o+9];   tot[2] = tot[2] + cap[0][o+10];
          tot[3] = tot[3] + cap[0][o+11];  tot[4] = tot[4] + cap[0][o+12];  tot[5] = tot[5] + cap[0][o+13];
          tot[6] = tot[6] + cap[0][o+14];  tot[7] = tot[7] + cap[0][o+15];  tot[8] = tot[8] + cap[0][o+16];
          tot[9] = tot[9] + cap[0][o+20];  tot[10] = tot[10] + cap[0][o+22]; tot[12] = tot[12] + cap[0][o+24];
          tot[11] = tot[11] + cap[0][o+27];
          if (f16(0, o+4) !== 16'hF800 || f16(0, o+6) !== 16'h1234) fail("sample CS:IP is not the constant the bench held");
          if (cap[0][o+17] !== 8'h5A || cap[0][o+18] !== 8'h3C || cap[0][o+19] !== 8'h81 || cap[0][o+25] !== 8'hE7 || cap[0][o+26] !== 8'h18)
            fail("sample PIC bytes are not the IMR/IRR/ISR the bench held");
          if (cap[0][o+21] !== 8'hA0) fail($sformatf("sample flags %02x, expected A0 (PE, IF)", cap[0][o+21]));
          if (seqprev >= 0 && cap[0][o+32] != ((seqprev + 1) & 255)) gaps = gaps + 1;
          seqprev = cap[0][o+32];
        end
      end
      for (i = 0; i < 13; i = i + 1)
        if (tot[i] != sum[i]) fail($sformatf("sampler counter %0d sums to %0d over %0d records, the bench drove %0d", i, tot[i], nsmp, sum[i]));
      if (nsmp < 40) fail($sformatf("only %0d samples in 30000 cycles of a 500-clock window", nsmp));
      if (gaps != 0) fail($sformatf("the sample sequence gapped %0d times with nothing skipped", gaps));
    end
    // E: INTR held high for a whole 10,000-clock window reads >= 1 in byte 23 (>>12), and the
    // flags byte shows it
    cpu_intr = 1'b1;
    tick(25000);
    cpu_intr = 1'b0;
    parse(4);
    begin : chi
      integer rr, best;
      best = 0;
      for (rr = 0; rr < nrec[4]; rr = rr + 1) begin
        o = rec_off[4][rr];
        if (cap[4][o+23] > best) best = cap[4][o+23];
      end
      if (best < 1 || best > 3) fail($sformatf("INTR-high byte peaked at %0d for a 10,000-cycle window (expected 2)", best));
      if (best >= 1 && best != 2) fail($sformatf("INTR-high byte peaked at %0d, expected 2 (10000>>12)", best));
    end

    // ---- 2. the snoop (DUT A) ----
    // writes in and out of the window, reads with bursts, overlapping requests, a beat with a write
    for (k = 0; k < 30; k = k + 1) begin
      bus_write(32'h0002_FA00 + 4 * k, (k % 4 == 0) ? 4'hF : (4'h1 << (k % 4)), rnd());
      bus_write(32'h0002_F9FC - 4 * k, 4'hF, rnd());           // below the window
      bus_write(32'h0002_FC00 + 4 * k, 4'hF, rnd());           // at and above its end
    end
    bus_write(32'h0002_FBFC, 4'hF, 32'hCAFE0001);              // the last dword of the window
    bus_write(32'h0002_FA00, 4'hF, 32'hCAFE0002);              // the first
    read_req(32'h0002_FA40, 8'd1, 1'b0); tick(3); read_beat(0, 0, 0);
    read_req(32'h0002_FA80, 8'd4, 1'b1); tick(2);
    read_beat(0, 0, 0); read_beat(0, 0, 0); read_beat(0, 0, 0); read_beat(0, 0, 0);
    read_req(32'h0002_FBF8, 8'd4, 1'b1); tick(2);             // runs off the end of the window
    for (k = 0; k < 4; k = k + 1) read_beat(0, 0, 0);
    read_req(32'h0001_0000, 8'd4, 1'b1); tick(2);             // outside entirely
    for (k = 0; k < 4; k = k + 1) read_beat(0, 0, 0);
    // three requests outstanding, then their beats
    read_req(32'h0002_FA10, 8'd2, 1'b0); read_req(32'h0002_FB00, 8'd1, 1'b0); read_req(32'h0002_FB10, 8'd4, 1'b1);
    tick(4);
    read_beat(0, 0, 0); read_beat(0, 0, 0); read_beat(0, 0, 0);
    for (k = 0; k < 4; k = k + 1) read_beat(0, 0, 0);
    // a response beat and an accepted write in the SAME cycle
    read_req(32'h0002_FA20, 8'd2, 1'b0); tick(2);
    read_beat(1, 32'h0002_FA30, 32'h5555_0001);
    tick(2);
    read_beat(1, 32'h0002_FA34, 32'h5555_0002);
    tick(4000);
    parse(0);
    check_events(0, 0);
    // two collision cycles back to back: the queue takes one entry a cycle, so exactly one event
    // (the second beat) is dropped and reported by a 0x32 record carrying a count of 1
    read_req(32'h0002_FA50, 8'd2, 1'b0); tick(2);
    read_beat(1, 32'h0002_FA54, 32'h6666_0001);
    read_beat(1, 32'h0002_FA58, 32'h6666_0002);
    tick(4000);
    parse(0);
    if (count_type(0, 8'h32) != 1) fail($sformatf("two back-to-back collisions produced %0d LOST records, expected 1", count_type(0, 8'h32)));
    else begin : coll
      integer rr2;
      for (rr2 = 0; rr2 < nrec[0]; rr2 = rr2 + 1)
        if (cap[0][rec_off[0][rr2]+1] == 8'h32 && f16(0, rec_off[0][rr2]+6) != 16'd1)
          fail($sformatf("the collision LOST record counts %0d, expected 1", f16(0, rec_off[0][rr2]+6)));
    end

    // ---- 3. the trace, RELOAD + second stage (DUT A) ----
    // issues run continuously; the order of the writes is the stimulus
    cpu_eip = 32'h0; iss_n = 0;
    for (k = 0; k < 40; k = k + 1) do_issue(16'h0100, 32'h2000 + k);
    bus_write(32'h0002_FB20, 4'hF, 32'h0000_0007);   // a nonzero write with no zero before it: nothing
    for (k = 0; k < 10; k = k + 1) do_issue(16'h0100, 32'h3000 + k);
    bus_write(32'h0002_FB20, 4'hC, 32'h0000_0000);   // the HIGH half only: does not cover the word
    bus_write(32'h0002_FB20, 4'h3, 32'h0000_0000);   // the zero write
    bus_write(32'h0003_D910, 4'hF, 32'hBAD0_BAD0);   // stage 2's window before stage 1: nothing
    for (k = 0; k < 10; k = k + 1) do_issue(16'h0100, 32'h4000 + k);
    bus_write(32'h0002_FB20, 4'h3, 32'h0000_BEEF);   // the reload: stage 1 fires
    for (k = 0; k < 80; k = k + 1) do_issue(16'h0100, 32'h5000 + k);   // far more than POST: still not frozen
    tick(300);
    if (ncap[0] != 0 && count_type(0, 8'h43) != 0) fail("the trace dumped after the first stage alone");
    do_issue(16'h0100, 32'h6000);
    t0 = iss_n - 1;                                   // the last issue before the second stage's trigger
    bus_write(32'h0003_D950, 4'hF, 32'hDEAD_BEEF);   // stage 2: the overwrite of the overlay
    for (k = 1; k < 40; k = k + 1) do_issue(16'h0100, 32'h6000 + k);
    tick(2000);
    parse(0);
    check_trace(0, 16, 32, 8'h02, 32'h0003_D950, 32'hDEAD_BEEF, 4'hF, t0);

    // ---- 4. the PC trigger, POST above 63 (DUT B) ----
    iss_n = 0;
    for (k = 0; k < 30; k = k + 1) do_issue(16'h1234, 32'h5000 + k);     // right CS, wrong EIP
    for (k = 0; k < 10; k = k + 1) do_issue(16'h4321, 32'h5678);          // right EIP, wrong CS
    do_issue(16'h1234, 32'h5678);                                         // the trigger issue
    t0 = iss_n - 1;                                                       // the trigger issue itself is recorded
    for (k = 0; k < 99; k = k + 1) do_issue(16'h1234, 32'h7000 + k);      // 99 post issues: not frozen yet
    tick(500);
    if (count_type(1, 8'h43) != 0 && ncap[1] != 0) fail("PC trace dumped before the POST-th (100th) issue");
    do_issue(16'h1234, 32'h7000 + 99);                                         // the 100th: freezes
    for (k = 0; k < 20; k = k + 1) do_issue(16'h1234, 32'h8000 + k);      // later issues are not recorded
    tick(1000);
    parse(1);
    check_trace(1, 8, 100, 8'h01, 32'h5678, 32'h1234, 4'h0, t0);

    // ---- 5. the WRITE trigger, POST = 0 (DUT C), long after the ARM delay ----
    iss_n = 20;                                           // C's first twenty issues were driven in step 0
    bus_write(32'h0000_1000, 4'h1, 32'h2222_2222);        // does not cover byte +2
    bus_write(32'h0000_1004, 4'h4, 32'h3333_3333);        // another dword
    tick(100);
    if (ncap[2] != 0) fail("the WRITE trigger fired on a write that does not cover its byte");
    for (k = 0; k < 10; k = k + 1) do_issue(16'h0200, 32'hA000 + k);
    t0 = iss_n - 1;
    bus_write(32'h0000_1000, 4'h4, 32'h4444_4444);        // covers it: fires
    tick(3);
    for (k = 0; k < 5; k = k + 1) do_issue(16'h0200, 32'hB000 + k);   // after the freeze: not recorded
    tick(1000);
    parse(2);
    check_trace(2, 8, 0, 8'h01, 32'h0000_1000, 32'h4444_4444, 4'h4, t0);

    // ---- 6. overrun (DUT D): a 128-byte ring, a 10-clock sampler, a queue flooded while stalled ----
    nxe[1] = 0; en[3] = 1'b0;
    for (k = 0; k < 900; k = k + 1) bus_write(32'h0000_8000 + 4 * (k % 1024), 4'hF, 32'h6000_0000 + k);
    for (rep = 0; rep < 3; rep = rep + 1) begin
      for (k = 0; k < 6; k = k + 1) read_req(32'h0000_8100 + 16 * k, 8'd4, 1'b1);
      for (k = 0; k < 24; k = k + 1) read_beat(0, 0, 0);
    end
    tick(300);
    en[3] = 1'b1;
    tick(3000);
    en[3] = 1'b0; tick(2000);                            // stall again mid-drain, then a random pace
    for (k = 0; k < 20000; k = k + 1) begin en[3] = (rnd() % 3 == 0); tick(1); end
    en[3] = 1'b1;
    tick(8000);
    parse(3);
    nev = 0; lostsum = 0; nlow = 0; gaps = 0; seqprev = -1; seqoff = -1;
    for (j = 0; j < nrec[3]; j = j + 1) begin
      o = rec_off[3][j];
      if (cap[3][o+1] == 8'h30 || cap[3][o+1] == 8'h31) nev = nev + 1;
      if (cap[3][o+1] == 8'h32) lostsum = lostsum + f16(3, o+6);
      if (cap[3][o+1] == 8'h21) nlow = nlow + 1;
      if (cap[3][o+1] == 8'h20 || cap[3][o+1] == 8'h21) begin
        if (seqprev >= 0 && cap[3][o+32] != ((seqprev + 1) & 255)) gaps = gaps + 1;
        seqprev = cap[3][o+32];
        // ms and the sequence number advance together (a 1 ms window): a record whose snapshot
        // was overwritten while it was being serialised mixes two ticks and breaks the relation
        if (seqoff < 0) seqoff = (cap[3][o+3] - cap[3][o+32]) & 255;
        else if (((cap[3][o+3] - cap[3][o+32]) & 255) != seqoff)
          fail($sformatf("overrun: sample at %0d is torn (ms %0d with sequence %0d)", o, cap[3][o+3], cap[3][o+32]));
      end
    end
    if (nev + lostsum != nxe[1])
      fail($sformatf("overrun: %0d events delivered + %0d reported lost = %0d, the bench drove %0d", nev, lostsum, nev + lostsum, nxe[1]));
    if (lostsum == 0) fail("overrun: nothing was lost, the load was not an overrun");
    if (nev == 0) fail("overrun: no events survived");
    if (nlow == 0) fail("overrun: no sample was flagged 0x21 after skipped ticks");
    if (gaps == 0) fail("overrun: the sample sequence never gapped although samples were skipped");

    // the captures, for tools/decode_dbglog.py (an end-to-end check of RTL bytes against the tool)
    if ($value$plusargs("DBGLOG_OUT=%s", dump_name)) begin
      for (k = 0; k < 4; k = k + 1) begin
        dump_fd = $fopen($sformatf("%0s.%0d", dump_name, k), "wb");
        for (i = 0; i < ncap[k]; i = i + 1) $fwrite(dump_fd, "%c", cap[k][i]);
        $fclose(dump_fd);
      end
    end

    // ==== VERDICT ====
    $display("dbg_cpu: samples %0d, snoop events A %0d / D delivered %0d + lost %0d", nsmp, nxe[0], nev, lostsum);
    if (errors != 0) $fatal(1, "TB_PC9821_DBG_CPU: %0d check(s) failed", errors);
    $display("TB_PC9821_DBG_CPU: PASS");
    $finish;
  end

  function automatic integer count_type(input integer d, input [7:0] t);
    integer i, c;
    begin
      c = 0; i = 0;
      while (i < ncap[d]) begin
        if (cap[d][i] == 8'hA5 && tlen(cap[d][i+1]) != 0) begin
          if (cap[d][i+1] == t) c = c + 1;
          i = i + tlen(cap[d][i+1]);
        end else i = ncap[d];
      end
      count_type = c;
    end
  endfunction

  // Every driven in-window event is in the capture exactly once (multiset), the stamps are
  // non-decreasing except for the one-cycle swap of a write and a beat in the same cycle, and no
  // event outside the window appears.
  task automatic check_events(input integer d, input integer w);
    integer rr, o, e, used_n;
    reg [0:MAXEV-1] used;
    reg matched;
    reg [31:0] cyc_last;
    begin
      used = {MAXEV{1'b0}}; used_n = 0; cyc_last = 32'h0;
      for (rr = 0; rr < nrec[d]; rr = rr + 1) begin
        o = rec_off[d][rr];
        if (cap[d][o+1] == 8'h30 || cap[d][o+1] == 8'h31) begin
          matched = 1'b0;
          for (e = 0; e < nxe[w] && !matched; e = e + 1)
            if (!used[e] && xe_read[w][e] == (cap[d][o+1] == 8'h31) && xe_addr[w][e] == f32(d, o+6) &&
                xe_aux[w][e] == cap[d][o+10][3:0] && xe_data[w][e] == f32(d, o+11)) begin
              used[e] = 1'b1; matched = 1'b1; used_n = used_n + 1;
            end
          if (!matched) fail($sformatf("snoop event at %0d (type %02x addr %08x data %08x) is not one the bench drove", o, cap[d][o+1], f32(d, o+6), f32(d, o+11)));
          if (f32(d, o+2) + 32'd2 < cyc_last) fail($sformatf("snoop event at %0d: cycle stamp went backwards (%0d after %0d)", o, f32(d, o+2), cyc_last));
          if (f32(d, o+2) > cyc_last) cyc_last = f32(d, o+2);
        end
      end
      if (used_n != nxe[w]) fail($sformatf("snoop: %0d of the %0d driven in-window events were reported", used_n, nxe[w]));
      if (count_type(d, 8'h32) != 0) fail("snoop: a LOST record appeared in an unloaded run");
    end
  endtask

  // The dump of a frozen trace: `depth` entries oldest first, the entry for issue number
  // (last - depth + 1 + idx), the trigger record. `last_issue` is the 1-based number of the last
  // issue the ring holds; entry content is derived from the bench's issue counter.
  task automatic check_trace(input integer d, input integer depth, input integer post, input [7:0] stage,
                             input [31:0] taddr, input [31:0] tdata, input [3:0] tbe, input integer last_pre);
    integer rr, o, idx, want, ntrc, ntrg;
    begin
      ntrc = 0; ntrg = 0;
      for (rr = 0; rr < nrec[d]; rr = rr + 1) begin
        o = rec_off[d][rr];
        if (cap[d][o+1] == 8'h43) begin
          idx = f16(d, o+2);
          if (idx != ntrc) fail($sformatf("trace entry %0d carries index %0d", ntrc, idx));
          // the ring ends at issue number last_pre + post and holds the `depth` issues up to it
          want = last_pre + post - depth + 1 + ntrc;
          ntrc = ntrc + 1;
          expect_issue(d, want, f16(d, o+4), f32(d, o+6), f16(d, o+10), f16(d, o+12));
        end
        if (cap[d][o+1] == 8'h44) begin
          ntrg = ntrg + 1;
          if (cap[d][o+2] != {6'd0, stage[1:0]}) fail($sformatf("trigger record of dut %0d: stage %0d, expected %0d", d, cap[d][o+2], stage));
          if (f32(d, o+3) != taddr) fail($sformatf("trigger record of dut %0d: address %08x, expected %08x", d, f32(d, o+3), taddr));
          if (f32(d, o+7) != tdata) fail($sformatf("trigger record of dut %0d: data %08x, expected %08x", d, f32(d, o+7), tdata));
          if (cap[d][o+11][3:0] != tbe) fail($sformatf("trigger record of dut %0d: byte enables %x, expected %x", d, cap[d][o+11][3:0], tbe));
          if (ntrc != depth) fail("the trigger record comes before the last trace entry");
        end
      end
      if (ntrc != depth) fail($sformatf("dut %0d dumped %0d trace entries, expected %0d", d, ntrc, depth));
      if (ntrg != 1) fail($sformatf("dut %0d wrote %0d trigger records, expected 1", d, ntrg));
    end
  endtask

  // The issue stream each trace DUT saw is a deterministic function of the stimulus above; the
  // bench regenerates (cs, eip) for issue number n of each phase.
  task automatic expect_issue(input integer d, input integer n, input [15:0] cs, input [31:0] eip,
                              input [15:0] sp, input [15:0] fl);
    reg [15:0] wcs; reg [31:0] weip;
    begin
      case (d)
        0: begin   // A: 40 @2000, 10 @3000, 10 @4000, 80 @5000, then 6000..  (cs 0100)
             wcs = 16'h0100;
             if (n < 40) weip = 32'h2000 + n;
             else if (n < 50) weip = 32'h3000 + (n - 40);
             else if (n < 60) weip = 32'h4000 + (n - 50);
             else if (n < 140) weip = 32'h5000 + (n - 60);
             else weip = 32'h6000 + (n - 140);
           end
        1: begin   // B: 30 @5000 (cs 1234), 10 @5678 cs 4321, the trigger, then 7000.. , 8000..
             if (n < 30) begin wcs = 16'h1234; weip = 32'h5000 + n; end
             else if (n < 40) begin wcs = 16'h4321; weip = 32'h5678; end
             else if (n == 40) begin wcs = 16'h1234; weip = 32'h5678; end
             else if (n < 141) begin wcs = 16'h1234; weip = 32'h7000 + (n - 41); end
             else begin wcs = 16'h1234; weip = 32'h8000 + (n - 141); end
           end
        default: begin   // C: 20 @9000, 10 @A000 (cs 0200)
             wcs = 16'h0200;
             if (n < 20) weip = 32'h9000 + n; else weip = 32'hA000 + (n - 20);
           end
      endcase
      if (cs !== wcs || eip !== weip)
        fail($sformatf("dut %0d trace issue %0d is %04x:%08x, expected %04x:%08x", d, n, cs, eip, wcs, weip));
      if (sp !== ((n[15:0] ^ 16'h5A5A)) || fl !== (n[15:0] + 16'h0202))
        fail($sformatf("dut %0d trace issue %0d carries SP %04x / FLAGS %04x, expected %04x / %04x", d, n, sp, fl, n[15:0] ^ 16'h5A5A, n[15:0] + 16'h0202));
    end
  endtask

  initial begin
    #80_000_000;
    $fatal(1, "the CPU instrument bench did not finish in 80 ms of simulated time");
  end
endmodule
