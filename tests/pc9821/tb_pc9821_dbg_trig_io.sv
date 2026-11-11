`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DBG_TRIG_IO: The CPU debug instrument's I/O trigger (pc9821_dbg_cpu TRIG_KIND 4, build_profile.py --dbg-trig io:PORT[:VAL]) freezes the instruction trace on the first OUT of VAL to PORT seen on the iobus's last-access latch after ARM_S - not on a match before ARM_S, an OUT of another byte, an OUT to another port, an IN that reads VAL from PORT, or a latch that holds the matching access without a new strobe - and dumps the last 2^TRACE_AW issues ending POST issues after it, followed by ONE trigger record tagged I/O that carries the port, the byte and a match count of 1; the any-byte form (io:PORT) fires on the first OUT of any byte; and the last-occurrence mode (LAST_MS, --dbg-last-ms) re-arms on every match, keeps its capture while the next one records into the other bank (a match inside the POST issues of the previous one restarts the count), dumps nothing while matches come closer together than LAST_MS, and once LAST_MS ms pass without a match dumps the capture of the LAST match - only the issues recorded since that bank was started, oldest first, through a ring wrap when there were more - with a trigger record marked last that counts every match since arming.
//
// WHY THIS EXISTS. Capturing the Windows 95 floppy hang (docs/user/dos-windows.md "Windows 95") needs the
// instructions around one FDC command byte, and the FDC's ports are answered inside the iobus, so neither the PC nor the WRITE trigger can find them. Every expected
// value below is computed from the STIMULUS (the issues and the latch strobes this bench drove),
// never from the DUT.

`default_nettype none

module tb_pc9821_dbg_trig_io;
  // ==== DUT ====
  reg clk = 1'b0;
  always #5 clk = ~clk;

  // the shared bus: only the issue port and the last-access latch move
  reg [15:0] cpu_cs = 16'h0028;
  reg [15:0] cpu_sp = 16'h0, cpu_flags = 16'h0;
  reg issue = 1'b0;
  reg [31:0] issue_eip = 32'h0;
  reg lio_stb = 1'b0, lio_wr = 1'b0;
  reg [15:0] lio_addr = 16'h0;
  reg [7:0] lio_data = 8'h0;

  localparam integer NI = 4;
  wire [NI-1:0] lw;
  wire [7:0]    lb [0:NI-1];
  wire [NI-1:0] acc = lw;            // the UART always takes the byte

  // F: io:92:0F, the first occurrence, behind a one-second ARM delay (10,000 clocks), POST 5,
  //    an 8-entry trace
  // G: io:92 (any byte), POST 0, an 8-entry trace
  // H: io:92 (any byte), the last occurrence after 50 quiet ms (500 clocks), POST 3
  // I: the same with 20 quiet ms (200 clocks)
  `define DTIO_PORTS(n) (.clk(clk), .cpu_cs(cpu_cs), .cpu_eip(32'h0), .cpu_pe(1'b0), .cpu_vm(1'b0), .cpu_if(1'b0), \
        .cpu_intr(1'b0), .cpu_sp(cpu_sp), .cpu_flags(cpu_flags), .inta_ready(1'b0), .inta_vec(8'h00), \
        .vsync_irq(1'b0), .io_wr(1'b0), .io_rd(1'b0), .io_addr(16'h0), .imr(8'h0), .irr(8'h0), .isr(8'h0), \
        .s_imr(8'h0), .s_isr(8'h0), .ata_block_read(1'b0), .gate_read(1'b0), .gate_addr(32'h0), \
        .issue(issue), .issue_eip(issue_eip), \
        .lio_stb(lio_stb), .lio_wr(lio_wr), .lio_addr(lio_addr), .lio_data(lio_data), \
        .m_valid(1'b0), .m_ready(1'b0), .m_write(1'b0), .m_addr(32'h0), .m_be(4'h0), .m_burst(8'h0), \
        .m_line(1'b0), .m_wdata(32'h0), .m_resp_valid(1'b0), .m_rdata(32'h0), \
        .log_byte(lb[n]), .log_we(lw[n]), .log_accept(acc[n]))
  pc9821_dbg_cpu #(.LOG_CLK_HZ(10_000), .RING_AW(11), .SAMPLER_EN(0), .SNOOP_EN(0), .TRIG_KIND(4),
      .TRIG_ADDR(32'h0000_920F), .ARM_S(1), .POST(5), .TRACE_AW(3)) uf `DTIO_PORTS(0);
  pc9821_dbg_cpu #(.LOG_CLK_HZ(10_000), .RING_AW(11), .SAMPLER_EN(0), .SNOOP_EN(0), .TRIG_KIND(4),
      .TRIG_ADDR(32'h0100_9200), .ARM_S(0), .POST(0), .TRACE_AW(3)) ug `DTIO_PORTS(1);
  pc9821_dbg_cpu #(.LOG_CLK_HZ(10_000), .RING_AW(11), .SAMPLER_EN(0), .SNOOP_EN(0), .TRIG_KIND(4),
      .TRIG_ADDR(32'h0100_9200), .ARM_S(0), .POST(3), .TRACE_AW(3), .LAST_MS(50)) uh `DTIO_PORTS(2);
  pc9821_dbg_cpu #(.LOG_CLK_HZ(10_000), .RING_AW(11), .SAMPLER_EN(0), .SNOOP_EN(0), .TRIG_KIND(4),
      .TRIG_ADDR(32'h0100_9200), .ARM_S(0), .POST(3), .TRACE_AW(3), .LAST_MS(20)) ui `DTIO_PORTS(3);
  `undef DTIO_PORTS

  // ==== STIMULUS ====
  integer errors = 0;
  task automatic fail(input string m);
    begin if (errors < 30) $display("FAIL: %0s", m); errors = errors + 1; end
  endtask

  localparam integer CAPN = 4000;
  reg [7:0] cap [0:NI-1][0:CAPN-1];
  integer   ncap [0:NI-1];
  integer   ci;
  initial for (ci = 0; ci < NI; ci = ci + 1) ncap[ci] = 0;
  always @(posedge clk) for (ci = 0; ci < NI; ci = ci + 1) if (acc[ci] && ncap[ci] < CAPN) begin
    cap[ci][ncap[ci]] = lb[ci];
    ncap[ci] = ncap[ci] + 1;
  end

  // issue number n carries EIP 0x1000 + n (and SP/FLAGS derived from n): the trace names its issues
  integer iss_n = 0;
  task automatic quiet_bus();
    begin issue = 1'b0; lio_stb = 1'b0; end
  endtask
  task automatic tick(input integer n);
    begin repeat (n) begin @(negedge clk); quiet_bus(); end end
  endtask
  task automatic do_issue();
    begin
      @(negedge clk); quiet_bus();
      issue = 1'b1; issue_eip = 32'h1000 + iss_n; cpu_sp = iss_n[15:0] ^ 16'h5A5A; cpu_flags = iss_n[15:0] + 16'h0202;
      iss_n = iss_n + 1;
    end
  endtask
  task automatic issues(input integer n);
    integer k;
    begin for (k = 0; k < n; k = k + 1) do_issue(); end
  endtask
  // one landed access on the latch: a strobe for one cycle, the latch then holds its value
  task automatic lio(input wr, input [15:0] a, input [7:0] d);
    begin
      @(negedge clk); quiet_bus();
      lio_stb = 1'b1; lio_wr = wr; lio_addr = a; lio_data = d;
    end
  endtask

  // ==== CHECKS ====
  function automatic integer tlen(input [7:0] t);
    case (t) 8'h43: tlen = 15; 8'h44: tlen = 13; default: tlen = 0; endcase
  endfunction
  function automatic [31:0] f32(input integer d, input integer o);
    f32 = {cap[d][o], cap[d][o+1], cap[d][o+2], cap[d][o+3]};
  endfunction
  function automatic [15:0] f16(input integer d, input integer o);
    f16 = {cap[d][o], cap[d][o+1]};
  endfunction
  // The capture of DUT d must be: `depth` 0x43 entries naming issues first..first+depth-1 in
  // order (index 0..depth-1), then one 0x44 record with the given stage byte, address and data.
  task automatic check_dump(input integer d, input string who, input integer depth, input integer first,
                            input [7:0] stage, input [31:0] taddr, input [31:0] tdata);
    integer i, l, ntrc, ntrg, n;
    begin
      i = 0; ntrc = 0; ntrg = 0;
      while (i < ncap[d]) begin
        l = (cap[d][i] == 8'hA5) ? tlen(cap[d][i+1]) : 0;
        if (l == 0 || i + l > ncap[d]) begin
          fail($sformatf("%0s: byte %0d is not a whole record (%02x %02x)", who, i, cap[d][i], cap[d][i+1]));
          i = ncap[d];
        end else begin
          if (cap[d][i+l-1] != 8'h5A) fail($sformatf("%0s: record at %0d lacks its 0x5A tail", who, i));
          if (cap[d][i+1] == 8'h43) begin
            n = first + ntrc;
            if (ntrg != 0) fail($sformatf("%0s: a trace entry after the trigger record", who));
            if (f16(d, i+2) != ntrc) fail($sformatf("%0s: entry %0d carries index %0d", who, ntrc, f16(d, i+2)));
            if (f16(d, i+4) != 16'h0028 || f32(d, i+6) != 32'h1000 + n ||
                f16(d, i+10) != (n[15:0] ^ 16'h5A5A) || f16(d, i+12) != n[15:0] + 16'h0202)
              fail($sformatf("%0s: entry %0d is %04x:%08x sp=%04x fl=%04x, expected issue %0d (0028:%08x)",
                             who, ntrc, f16(d, i+4), f32(d, i+6), f16(d, i+10), f16(d, i+12), n, 32'h1000 + n));
            ntrc = ntrc + 1;
          end else begin
            if (cap[d][i+2] != stage) fail($sformatf("%0s: trigger stage byte %02x, expected %02x", who, cap[d][i+2], stage));
            if (f32(d, i+3) != taddr) fail($sformatf("%0s: trigger address %08x, expected %08x", who, f32(d, i+3), taddr));
            if (f32(d, i+7) != tdata) fail($sformatf("%0s: trigger data %08x, expected %08x", who, f32(d, i+7), tdata));
            if (cap[d][i+11] != 8'h00) fail($sformatf("%0s: trigger byte enables %02x, expected 00", who, cap[d][i+11]));
            ntrg = ntrg + 1;
          end
          i = i + l;
        end
      end
      if (ntrc != depth) fail($sformatf("%0s: %0d trace entries, expected %0d", who, ntrc, depth));
      if (ntrg != 1) fail($sformatf("%0s: %0d trigger records, expected 1", who, ntrg));
    end
  endtask

  integer t_f, t_g, t2, t3;
  initial begin
    tick(6);

    // ---- 1. the last occurrence (H, I), the any-byte trigger (G), and F before its ARM delay ----
    // all of it inside F's first second (10,000 clocks)
    issues(20);                      // issues 0..19
    t_g = iss_n;
    lio(1'b1, 16'h0092, 8'h0F);      // match 1: G freezes (POST 0); F is not armed yet
    tick(2);                         // (POST 0 freezes the cycle after the trigger)
    issues(3);                       // 20..22: H/I commit match 1 (bank 0: the last 8 = 15..22)
    issues(12);                      // 23..34 into bank 1, which wraps
    lio(1'b1, 16'h0092, 8'h02);      // match 2
    issues(3);                       // 35..37: H/I commit match 2 (bank 1: 30..37)
    t2 = iss_n;
    tick(300);                       // 30 ms without a match: I (20 ms) dumps match 2, H (50 ms) waits
    if (ncap[2] != 0) fail("H: dumped after 30 ms without a match (its quiet period is 50 ms)");
    issues(1);                       // 38: the first entry of the restarted bank 0
    t3 = iss_n - 1;
    lio(1'b1, 16'h0092, 8'h03);      // match 3
    issues(1);                       // 39
    lio(1'b1, 16'h0092, 8'h04);      // match 4, inside match 3's POST: the count restarts
    issues(3);                       // 40..42: H commits match 4 (bank 0: 38..42, five entries)
    issues(2);                       // 43..44: into bank 1, not the capture
    tick(400);                       // 40 ms after match 4: still nothing
    if (ncap[2] != 0) fail("H: dumped 40 ms after the last match (its quiet period is 50 ms)");
    tick(400);                       // past 50 ms: H dumps match 4
    check_dump(2, "H last occurrence (part of a bank)", 5, t3, 8'h45, 32'h0000_0092, 32'h0000_0404);
    // I dumped match 2 (a full, wrapped bank) and froze: matches 3 and 4 did not disturb it
    check_dump(3, "I last occurrence (full bank)", 8, t2 - 8, 8'h45, 32'h0000_0092, 32'h0000_0202);
    // G: the 8 issues before the first OUT, then its trigger (match 1, byte 0F)
    check_dump(1, "G any-byte", 8, t_g - 8, 8'h41, 32'h0000_0092, 32'h0000_010F);
    if (ncap[0] != 0) fail("F: the I/O trigger fired before ARM_S seconds");

    // ---- 2. after ARM_S (F): only the exact OUT fires ----
    tick(10_200);                    // the one-second ARM delay (10,000 clocks) has passed
    issues(12);
    lio(1'b1, 16'h0092, 8'h0E);      // another byte
    issues(2);
    lio(1'b1, 16'h0090, 8'h0F);      // another port (the FDC's status port)
    issues(2);
    lio(1'b1, 16'h0192, 8'h0F);      // a port that differs above bit 7
    issues(2);
    lio(1'b0, 16'h0092, 8'h0F);      // an IN that reads 0F from the port
    issues(2);
    @(negedge clk); quiet_bus();     // the latch holds the matching OUT but WITHOUT its strobe
    lio_wr = 1'b1; lio_addr = 16'h0092; lio_data = 8'h0F;
    issues(2);
    tick(200);
    if (ncap[0] != 0) fail("F: the I/O trigger fired on an access that is not an OUT of 0F to 0x92");
    issues(3);
    t_f = iss_n;                     // the trigger: the last issue before it is t_f - 1
    lio(1'b1, 16'h0092, 8'h0F);
    tick(2);                         // the latch keeps holding the match: no second trigger
    issues(4);                       // 4 of the 5 POST issues: not frozen yet
    tick(200);
    if (ncap[0] != 0) fail("F: the trace dumped before the POST-th issue");
    issues(1);                       // the fifth: freezes
    lio(1'b1, 16'h0092, 8'h0F);      // a later match does not fire again
    issues(10);                      // nor are later issues recorded
    tick(400);
    // the ring: the 8 issues ending with the fifth POST issue (t_f + 4); match 1 of F (the
    // matches before ARM_S are not counted)
    check_dump(0, "F first occurrence", 8, t_f + 5 - 8, 8'h41, 32'h0000_0092, 32'h0000_010F);
    // ==== VERDICT ====
    if (errors != 0) begin
      $fatal(1, "TB_PC9821_DBG_TRIG_IO: %0d check(s) failed", errors);
    end
    $display("TB_PC9821_DBG_TRIG_IO: PASS");
    $finish;
  end

  initial begin
    #5_000_000;
    $fatal(1, "TB_PC9821_DBG_TRIG_IO: TIMEOUT");
  end
endmodule
