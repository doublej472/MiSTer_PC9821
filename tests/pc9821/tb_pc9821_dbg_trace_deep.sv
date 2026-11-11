`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DBG_TRACE_DEEP: The CPU debug instrument's PC trigger (pc9821_dbg_cpu TRIG_KIND 1, build_profile.py --dbg-trig pc:CS:EIP) matches a virtual-8086 code address by its segment value (pc:FD80:1A82 fires on the issue at FD80:00001A82 and not on 0028:00001A82, FD81:00001A82, 7D80:00001A82, FD80:00001A83 or FD80:00011A82), and a 2^12-entry ring (TRACE_AW 12, build_profile.py --dbg-trace-aw 12) in the last-occurrence mode with POST 4095 dumps the capture of the LAST match: exactly 4096 entries, indices 0..4095, the matching issue first and the 4095 issues after it in order, then one trigger record marked last naming FD80:1A82.
//
// WHY THIS EXISTS. Captures of the Windows 95 720 KB floppy hang (docs/user/dos-windows.md "Windows 95") trigger
// on the System VM's real-mode INT 1Bh entry (FD80:1A82, a V86 address) and need 4095 issues
// after a trigger, which the default 2^9 ring cannot hold. Every expected value below is computed from the STIMULUS (the issues this bench
// drove), never from the DUT.

`default_nettype none

module tb_pc9821_dbg_trace_deep;
  // ==== DUT ====
  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg [15:0] cpu_cs = 16'h0028;
  reg [15:0] cpu_sp = 16'h0, cpu_flags = 16'h0;
  reg cpu_pe = 1'b1, cpu_vm = 1'b0;
  reg issue = 1'b0;
  reg [31:0] issue_eip = 32'h0;

  localparam integer NI = 2;
  wire [NI-1:0] lw;
  wire [7:0]    lb [0:NI-1];
  wire [NI-1:0] acc = lw;            // the UART always takes the byte

  // J: pc:FD80:1A82, the last occurrence after 1000 quiet ms (10,000 clocks), POST 4095, a 2^12 ring
  // K: pc:FD80:1A82, the first occurrence, POST 2, a 16-entry ring
  `define DTD_PORTS(n) (.clk(clk), .cpu_cs(cpu_cs), .cpu_eip(32'h0), .cpu_pe(cpu_pe), .cpu_vm(cpu_vm), .cpu_if(1'b0), \
        .cpu_intr(1'b0), .cpu_sp(cpu_sp), .cpu_flags(cpu_flags), .inta_ready(1'b0), .inta_vec(8'h00), \
        .vsync_irq(1'b0), .io_wr(1'b0), .io_rd(1'b0), .io_addr(16'h0), .imr(8'h0), .irr(8'h0), .isr(8'h0), \
        .s_imr(8'h0), .s_isr(8'h0), .ata_block_read(1'b0), .gate_read(1'b0), .gate_addr(32'h0), \
        .issue(issue), .issue_eip(issue_eip), \
        .lio_stb(1'b0), .lio_wr(1'b0), .lio_addr(16'h0), .lio_data(8'h0), \
        .m_valid(1'b0), .m_ready(1'b0), .m_write(1'b0), .m_addr(32'h0), .m_be(4'h0), .m_burst(8'h0), \
        .m_line(1'b0), .m_wdata(32'h0), .m_resp_valid(1'b0), .m_rdata(32'h0), \
        .log_byte(lb[n]), .log_we(lw[n]), .log_accept(acc[n]))
  pc9821_dbg_cpu #(.LOG_CLK_HZ(10_000), .RING_AW(11), .SAMPLER_EN(0), .SNOOP_EN(0), .TRIG_KIND(1),
      .TRIG_CS(16'hFD80), .TRIG_ADDR(32'h0000_1A82), .ARM_S(0), .POST(4095), .TRACE_AW(12),
      .LAST_MS(1000)) uj `DTD_PORTS(0);
  pc9821_dbg_cpu #(.LOG_CLK_HZ(10_000), .RING_AW(11), .SAMPLER_EN(0), .SNOOP_EN(0), .TRIG_KIND(1),
      .TRIG_CS(16'hFD80), .TRIG_ADDR(32'h0000_1A82), .ARM_S(0), .POST(2), .TRACE_AW(4)) uk `DTD_PORTS(1);
  `undef DTD_PORTS

  // ==== STIMULUS ====
  integer errors = 0;
  task automatic fail(input string m);
    begin if (errors < 30) $display("FAIL: %0s", m); errors = errors + 1; end
  endtask

  localparam integer CAPN = 70000;
  reg [7:0] cap [0:NI-1][0:CAPN-1];
  integer   ncap [0:NI-1];
  integer   ci;
  initial for (ci = 0; ci < NI; ci = ci + 1) ncap[ci] = 0;
  always @(posedge clk) for (ci = 0; ci < NI; ci = ci + 1) if (acc[ci] && ncap[ci] < CAPN) begin
    cap[ci][ncap[ci]] = lb[ci];
    ncap[ci] = ncap[ci] + 1;
  end

  // every issue is remembered by number, so a dump is checked against what was driven
  localparam integer MAXI = 12000;
  reg [15:0] i_cs [0:MAXI-1];
  reg [31:0] i_eip [0:MAXI-1];
  reg [15:0] i_sp [0:MAXI-1];
  reg [15:0] i_fl [0:MAXI-1];
  integer iss_n = 0;
  task automatic quiet_bus();
    begin issue = 1'b0; end
  endtask
  task automatic tick(input integer n);
    begin repeat (n) begin @(negedge clk); quiet_bus(); end end
  endtask
  task automatic do_issue(input [15:0] cs, input [31:0] eip, input vm);
    begin
      @(negedge clk); quiet_bus();
      issue = 1'b1; cpu_cs = cs; issue_eip = eip; cpu_vm = vm;
      cpu_sp = iss_n[15:0] ^ 16'h5A5A; cpu_flags = iss_n[15:0] + 16'h0202;
      i_cs[iss_n] = cs; i_eip[iss_n] = eip; i_sp[iss_n] = cpu_sp; i_fl[iss_n] = cpu_flags;
      iss_n = iss_n + 1;
    end
  endtask
  // n ring-0 issues (0028:C000xxxx) or n V86 issues inside the ROM segment that never hit the
  // trigger's offset (FD80:8000-FFFF; the trigger's 0x1A82 has bit 15 clear)
  task automatic ring0(input integer n);
    integer k;
    begin for (k = 0; k < n; k = k + 1) do_issue(16'h0028, 32'hC000_0000 + iss_n, 1'b0); end
  endtask
  task automatic v86(input integer n);
    integer k;
    begin for (k = 0; k < n; k = k + 1) do_issue(16'hFD80, {16'h0, 1'b1, iss_n[14:0]}, 1'b1); end
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
  // DUT d's capture must be `depth` 0x43 entries naming issues first..first+depth-1 in order
  // (index 0..depth-1), then one 0x44 record with the given stage byte, address and data.
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
            if (f16(d, i+2) != ntrc[15:0]) fail($sformatf("%0s: entry %0d carries index %0d", who, ntrc, f16(d, i+2)));
            if (n >= MAXI) fail($sformatf("%0s: entry %0d is past the last issue driven", who, ntrc));
            else if (f16(d, i+4) != i_cs[n] || f32(d, i+6) != i_eip[n] || f16(d, i+10) != i_sp[n] ||
                     f16(d, i+12) != i_fl[n])
              fail($sformatf("%0s: entry %0d is %04x:%08x sp=%04x fl=%04x, expected issue %0d (%04x:%08x)",
                             who, ntrc, f16(d, i+4), f32(d, i+6), f16(d, i+10), f16(d, i+12), n, i_cs[n], i_eip[n]));
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

  integer m1, m2, last_n;
  initial begin
    tick(6);
    // ---- the near misses: same offset in ring 0, a neighbouring segment, a segment differing only
    // in bit 15, the next offset, and EIP bits above 15 set ----
    ring0(40);
    do_issue(16'h0028, 32'h0000_1A82, 1'b0);
    v86(3);
    do_issue(16'hFD81, 32'h0000_1A82, 1'b1);
    do_issue(16'h7D80, 32'h0000_1A82, 1'b1);
    do_issue(16'hFD80, 32'h0000_1A83, 1'b1);
    do_issue(16'hFD80, 32'h0001_1A82, 1'b1);
    v86(5);
    tick(50);
    if (ncap[1] != 0) fail("K: the PC trigger fired on an issue that is not FD80:00001A82");
    // ---- match 1 (K's trigger; J's first candidate), then more than a ring of issues ----
    ring0(10);
    m1 = iss_n;
    do_issue(16'hFD80, 32'h0000_1A82, 1'b1);
    v86(4200);
    tick(50);
    // K: its 16 issues ending with the second POST issue
    check_dump(1, "K first occurrence (V86)", 16, m1 + 3 - 16, 8'h01, 32'h0000_1A82, 32'h0000_FD80);
    if (ncap[0] != 0) fail("J: dumped while matches were less than its quiet period apart");
    // ---- match 2: J's capture is the LAST one, 4096 entries from the match ----
    ring0(30);
    m2 = iss_n;
    do_issue(16'hFD80, 32'h0000_1A82, 1'b1);
    v86(4300);
    ring0(100);
    tick(11_000);                    // past the 1000 ms quiet period
    // the dump drains (4097 records, about two clocks a byte): wait until the capture stops growing
    last_n = -1;
    while (ncap[0] != last_n) begin last_n = ncap[0]; tick(2_000); end
    check_dump(0, "J last occurrence, 2^12 ring, POST 4095", 4096, m2, 8'h05, 32'h0000_1A82, 32'h0000_FD80);
    // ==== VERDICT ====
    if (errors != 0) begin
      $fatal(1, "TB_PC9821_DBG_TRACE_DEEP: %0d check(s) failed", errors);
    end
    $display("TB_PC9821_DBG_TRACE_DEEP: PASS");
    $finish;
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_DBG_TRACE_DEEP: TIMEOUT");
  end
endmodule
