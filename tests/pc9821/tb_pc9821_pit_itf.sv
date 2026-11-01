`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The ITF's own PIT self-test sequence, from the firmware dump: for each of its three (control, data, latch) triples the channel must still be counting when the latch is read, so the data port answers with a live count rather than the 0xFF the test just wrote into it. A PIT whose data port echoes the last written byte halts the authentic POST with TIMER ERROR before the option ROM, and a PIT whose latch is never consumed freezes the channel for the rest of the session.
//
// ---- where the expectation comes from ----
//
// THE ITF'S OWN SELF-TEST, disassembled from the firmware dump rather than
// inferred from our RTL. Its entry is BANK4@0x373 (physical 0xF8373; BANK4 maps
// at 0xF8000, so file offset = physical - 0xF8000):
//
//   000F8383  mov si,0x3d7        ; the control/data port pairs
//   000F8386  mov di,0x3e3        ; the two control words per pair
//   000F8389  mov cx,0x3          ; three iterations
//   000F838C  mov bp,0xffff
//   000F838F  mov al,[cs:di]      ; A_n  -- program the channel
//   000F8392  mov dx,[cs:si]      ;       the CONTROL port
//   000F8397  out dx,al
//   000F8398  mov dx,[cs:si+0x2]  ;       the DATA port
//   000F839C  mov ax,bp           ;       AX = 0xFFFF on the first pass
//   000F839E  out dx,al           ;       data <- 0xFF
//   000F839F  xchg bx,dx
//   000F83A1  mov al,[cs:di+0x1]  ; B_n  -- the latch command
//   000F83A5  out dx,al
//   000F83A6  xchg bx,dx
//   000F83A8  in  al,dx           ; READ the data port back
//   000F83A9  cmp ah,al           ; AH is 0xFF on the first pass
//   000F83AB  jnz 0x83b9          ; differs -> this pair is good
//   000F83AD  mov si,0x2b39       ; else: cs:0x2b39 = "TIMER ERROR"
//   000F83B3  jmp 0xe160
//   000F83B6  hlt
//   000F83B7  jmp 0x83b7          ; and a halt loop
//
// The tables it walks, also from the dump:
//   ports  at cs:0x3d7 = 0077 0071 | 3fdf 3fdb | 0077 0075
//   words  at cs:0x3e3 = 10 00     | 50 40     | 90 80
//
// So the sequence is, three times over: write a control word, write 0xFF to
// that channel's data port, write a SECOND control word which is a counter
// latch (RL = 00), then read the data port and require it NOT to be 0xFF. The
// requirement is that the channel kept counting across those writes and the
// latch returned the live count. Three things about this are worth stating
// because they are the whole content of the test:
//
//  1. THE SECOND CONTROL WORD IS A LATCH AND THE FIRST IS NOT. A_n = 0x10/0x50/
//     0x90 has RL = 01 and mode 0 (channel 0), mode 2 (channel 1) and mode 0
//     (channel 2); B_n = 0x00/0x40/0x80 has RL = 00, the latch command. So the
//     ITF relies on a mode-set NOT stopping a channel it had already given a
//     count to, and on a latch command not disturbing one either.
//
//  2. THE SECOND ITERATION GOES THROUGH THE ALIAS. Its ports are 0x3FDF and
//     0x3FDB, the same two PIT registers reached at the odd addresses of
//     0x3FD9..0x3FDF. This bench drives pc9821_pit directly, so it models that
//     alias the only way a PIT-only bench can: by passing the alias PORT NUMBER
//     and letting the bench compute addr = port[2:1], which is what
//     pc9821_interrupts hands the PIT (0x77 -> 3, 0x71 -> 0, 0x3FDF -> 3,
//     0x3FDB -> 1). The DECODE that produces the chip select for the alias
//     lives in pc9821_device_select and is swept address-by-address by
//     tb_pc9821_device_select; what is unpinned until now is the PIT's
//     behaviour once the alias reaches it.
//     [source: the tree's own account of the alias, pc9821_interrupts.sv, which
//     cites QEMU i8254-pc98.c:472 and NP2kai pit.c:539-545 for the mapping]
//
//  3. THE COUNT HAS TO HAVE MOVED. The read is against 0xFF, the byte just
//     written, so any PIT that answers with the last written byte -- a channel
//     that never started, or a latch that returns the reload rather than the
//     count -- reads 0xFF and fails. That is the failure the RTL's own comment
//     records as having happened, and it is the one this bench is built to
//     catch. [source: src/pc9821/timers/pc9821_pit.sv's comment on the mode-set
//     path, which names BANK4@0x373 for exactly this test]
//
//  4. AND THE COUNT ONLY MOVES BECAUSE THE BUS IS SLOW. This is the assumption
//     worth writing down, because it is invisible in the RTL and it is what
//     makes the test discriminating at all. The ITF's data write and its latch
//     command are two separate bus accesses, and it is the bus access time
//     between them -- not anything the PIT does -- that lets the counter
//     advance. Written with the accesses back to back, this bench FAILED on the
//     current RTL for all three pairs, because the latch then holds 0xFF, the
//     count at the instant of the write, and reads back 0xFF.
//
//     So the bench spaces its accesses by a fixed gap, and the number is
//     sourced rather than chosen. The core's per-class table now carries the
//     8253 ports at the ITF floor (21 clk_sys): that is 420 ns, just
//     over the 407 ns of one source tick, and it is the BUS half of the gap
//     alone. On the machine the same gap also carries the CPU's own OUT
//     instruction time, so the bench keeps GAP_TICKS at 9 source ticks -- a
//     conservative model of the full inter-write gap, well above the one-tick
//     minimum, rather than the bare bus access.
//
//     THE CONSEQUENCE, stated because it is a real coupling and nobody has
//     written it down: the ITF's timer self-test is a test of the BUS, not only
//     of the PIT. If the core's I/O wait for the 8253 ports ever falls below one
//     PIT tick, this sequence reads 0xFF and the POST halts with TIMER ERROR on
//     a PIT that is behaving correctly. That is why the 8253 ports keep the
//     floor when every other class takes the machine's measured value.
//
// WHAT IT WOULD TAKE TO PASS WRONGLY. A PIT whose data port always returned a
// constant other than 0xFF would pass the inequality and fail the moved-count
// check below; a PIT whose latch returned a stale count from before the reload
// would fail the same check; a PIT that stopped the channel on the latch
// command would fail it too. What this bench does NOT pin is the I/O access
// latency itself -- that belongs to pc9821_iobus's per-class wait table and to
// tb_pc9821_iobus -- but it does depend on it, so the dependency is named here
// rather than left implicit.

module tb_pc9821_pit_itf;

  reg clk = 0;
  // 50 MHz, the rate pc9821_interrupts is instantiated at, so the tick enable
  // is the one the hardware produces.
  always #10 clk = ~clk;
  reg rst_n = 0;
  reg cs = 0, wr = 0, rd = 0;
  reg  [1:0] addr = 0;
  reg  [7:0] din = 0;
  wire [7:0] dout;
  wire out0, out1, out2;

  // ==== DUT ====
  pc9821_pit #(.SYS_CLOCK_HZ(50_000_000)) dut (
      .clk(clk), .rst_n(rst_n), .cs(cs), .addr(addr),
      .wr(wr), .rd(rd), .din(din), .dout(dout),
      .out0(out0), .out1(out1), .out2(out2)
  );

  integer errors = 0;
  // ==== STIMULUS ====

  // The PIT's register index is the port's [2:1], for both the 0x71 range and
  // the 0x3FD9 alias -- the mapping pc9821_interrupts passes down.
  task automatic wr_port(input [15:0] port, input [7:0] value);
    begin
      @(negedge clk);
      addr = port[2:1];
      din  = value;
      cs   = 1;
      wr   = 1;
      @(posedge clk);
      @(negedge clk);
      cs = 0;
      wr = 0;
    end
  endtask

  task automatic rd_port(input [15:0] port, output [7:0] value);
    begin
      @(negedge clk);
      addr = port[2:1];
      cs   = 1;
      rd   = 1;
      @(posedge clk);
      value = dout;
      @(negedge clk);
      cs = 0;
      rd = 0;
    end
  endtask

  // Wait for n source ticks, the way the firmware's accesses are separated by
  // real time on the bus.
  task automatic wait_ticks(input integer n);
    integer seen;
    begin
      seen = 0;
      while (seen < n) begin
        @(posedge clk);
        if (dut.pit_tick) seen = seen + 1;
      end
    end
  endtask

  integer i;
  reg [7:0] got;
  reg [7:0] first_read;
  // The gap the firmware's accesses actually have on the bus: a system-class
  // port at the machine's measured ~3.7 us is 9 source ticks at 2.4576 MHz.
  // See point 4 in the header -- the ITF's latch only differs from its data
  // write because of this interval, so the bench has to model it.
  localparam integer GAP_TICKS = 9;
  reg [15:0] ctl_port [0:2];
  reg [15:0] dat_port [0:2];
  reg [7:0] ctl_a [0:2];
  reg [7:0] ctl_b [0:2];
  // ==== CHECKS ====

  initial begin
    // The ITF's three pairs, verbatim from the dump's two tables.
    ctl_port[0] = 16'h0077; dat_port[0] = 16'h0071; ctl_a[0] = 8'h10; ctl_b[0] = 8'h00;
    ctl_port[1] = 16'h3FDF; dat_port[1] = 16'h3FDB; ctl_a[1] = 8'h50; ctl_b[1] = 8'h40;
    ctl_port[2] = 16'h0077; dat_port[2] = 16'h0075; ctl_a[2] = 8'h90; ctl_b[2] = 8'h80;

    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);

    // ---- the ITF's sequence, once per pair ----
    for (i = 0; i < 3; i = i + 1) begin
      wr_port(ctl_port[i], ctl_a[i]);   // program: RL = 01, a mode
      wr_port(dat_port[i], 8'hFF);      // reload 0xFF; the channel starts
      // One bus access elapses here on the machine. Without it the count is
      // still 0xFF when the latch is taken and the read below is 0xFF for a
      // correct PIT -- which is exactly what this bench did before GAP_TICKS.
      wait_ticks(GAP_TICKS);
      wr_port(ctl_port[i], ctl_b[i]);   // RL = 00: the latch command
      rd_port(dat_port[i], got);
      // BANK4@0x83A9: cmp ah,al with AH = 0xFF -- a read of 0xFF is the
      // failure, and it halts the POST with "TIMER ERROR" at cs:0x2b39.
      if (got === 8'hFF) begin
        $display("FAIL pair %0d (ctl %04x dat %04x): data port read back 0xFF, the byte just written", i, ctl_port[i], dat_port[i]);
        errors = errors + 1;
      end
    end

    // ---- and it is a MOVED count, not a constant that merely differs ----
    // Channel 0, LSB-only, mode 0, reload 0xFF. Latch it, read, wait, latch and
    // read again: the second count must be lower, which is the property the
    // ITF's inequality is a proxy for.
    wr_port(16'h0077, 8'h10);
    wr_port(16'h0071, 8'hFF);
    wait_ticks(GAP_TICKS);
    wr_port(16'h0077, 8'h00);          // latch
    rd_port(16'h0071, first_read);
    wait_ticks(GAP_TICKS);
    wr_port(16'h0077, 8'h00);          // latch again
    rd_port(16'h0071, got);
    if (got >= first_read) begin
      $display("FAIL live count did not advance across a bus access: %02x then %02x", first_read, got);
      errors = errors + 1;
    end
  // ==== VERDICT ====

    if (errors == 0) begin
        $display("TB_PC9821_PIT_ITF: PASS");
        $finish;
    end
    else $fatal(1, "TB_PC9821_PIT_ITF: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_PIT_ITF: TIMEOUT");
  end

endmodule
