`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_MPU_PROBE: The DOS probe MPUTEST's /BYTES op script (tools/hwprobe/mputest, generated into mputest_bytes.svh), run through pc9821_system's real I/O bus with the probe's own access discipline (BUSY bit 6 polled before every command and data write, status bit 7 polled after every command, the ACK read and any further queued byte drained), is ACKed 0xFE for every command the reference ACKs (every intelligent-mode command, not the 0xFF that leaves UART mode, which the Roland MPU-401 manual does not ACK) and puts on the card's 31250-baud MIDI line exactly the byte stream NP2kai's cbus/mpu98ii.c produces for it - both 0xFF and 0x3F all-notes-off bursts, UART-mode bytes byte-exact including running status and a 140-byte SysEx, 0xFF in UART mode leaving it with no burst and no ACK, 0xD0 running status expanded to a full status byte and 0xDF SysEx passed - with no byte missing, extra or reordered; a blind burst (200 bytes written back to back in UART mode with no BUSY poll, once while the 0x3F burst is still going out and once 100 ms after 0x3F as the probe's /RAW does it) is MEASURED and REPORTED, not asserted.
//
// WHERE THE EXPECTED BYTES COME FROM. MPUTEST_WIRE and MPUTEST_ACK are computed by
// tools/hwprobe/mputest/mputest_decode.py's reference model (class Card, model "manual"),
// whose wire encodes NP2kai cbus/mpu98ii.c: sendmpureset's 16 x {B0+ch, 7B, 00} from both
// mpucmd_ff and mpucmd_3f, UART-mode data written to the line as is (mpu98ii_o0), UART-mode
// 0xFF leaving it with `mpu98.mode = 0;` and no burst, and sendmpumsg's running-status
// expansion. Its ACKs are the Roland MPU-401 Technical Reference Manual's: every command but
// the 0xFF that leaves UART mode (section 5.3, "The MPU-401 will not return an ACK ($FE) in
// this one case."), which NP2kai ACKs and a real MPU-PC98 does not (todo item 173). This bench
// never derives a byte from the RTL. The same script, byte for
// byte, is what MPUTEST.COM runs on the core and on a real card (its capture carries the
// tables' CRC-32), so a card's wire capture is compared against the same expectation.
//
// THE RAW REPORT. A real MPU-401-family card's DRR (status bit 6) is the only flow control a
// host has; a writer that ignores it loses bytes on any card. How many this core loses is a
// model property (TX queue depth 32, one parked byte), recorded here so a change to it is
// visible; NP2kai has no loss on that path (mpu98ii_o0 hands each byte to the host's MIDI
// out), and no capture of a real card exists yet, so there is nothing to assert.
//
// The CPU side is forced exactly as tb_pc9821_mpu_system does it (z486_stub, cpu_run forced).

`default_nettype none

module tb_pc9821_mpu_probe;
  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;           // 50 MHz
  reg reset = 1;
  wire [55:0] rtc = 56'h05_26_09_12_12_34_56;
  integer errors = 0;
  localparam integer BIT_CYCLES = 1600;    // 50_000_000 / 31250

  `include "mputest_bytes.svh"

  // ==== DUT ====
  reg [31:2] cpu_addr = 30'd0;
  reg [3:0]  cpu_be = 4'd0;
  reg        cpu_write = 1'b0;
  reg [31:0] cpu_din = 32'd0;
  reg        valid_on = 1'b0;
  wire       mpu_line;

  pc9821_system #(.SYS_FREQ(50_000_000), .DCACHE_SET_BITS(4), .ICACHE_SET_BITS(4), .ENABLE_X87(1'b0),
      .MPU_EN(1'b1)) dut (
      .clk_sys(clk_sys), .reset(reset), .hps_apply_reset(1'b0), .rtc(rtc), .software_reset(),
      .joystick_dis(2'd0), .joystick_dig_1(14'd0), .joystick_dig_2(14'd0),
      .joystick_ana_1(16'd0), .joystick_ana_2(16'd0), .joystick_mode(2'd0), .joystick_timed(2'd0),
      .ext_mem_busy(1'b0),
      .ext_mem0_dout(32'd0), .ext_mem0_resp_valid(1'b0), .ext_mem0_ready(1'b1),
      .ext_mem1_dout(32'd0), .ext_mem1_resp_valid(1'b0), .ext_mem1_ready(1'b1),
      .ext_mem2_dout(32'd0), .ext_mem2_resp_valid(1'b0), .ext_mem2_ready(1'b1),
      .ioctl_download(1'b0), .ioctl_index(16'd0), .ioctl_wr(1'b0), .ioctl_addr(27'd0), .ioctl_dout(16'd0),
      .img_mounted(1'b0), .img_readonly(1'b0), .img_size(64'd0), .img_ack(1'b0), .img_buff_addr(13'd0),
      .img_buff_din(16'd0), .img_buff_wr(1'b0),
      .ps2_kbclk_in(1'b1), .ps2_kbdat_in(1'b1), .ps2_key(11'd0),
      .dbg_uart_byte(), .dbg_uart_we(), .dbg_uart_accept(1'b1), .sdph_step_req(), .sdph_step_up(), .sdph_step_ack(1'b0), .sdph_fault(1'b0), .trace_trig(),
      .ram_size(3'd5), .ram_size_max(3'd7), .bios_set(4'd0),
      .mpu_present(1'b1), .mpu_uart_tx(mpu_line));

  initial begin
    // cpu_run is forced at its DRIVER, the loader's register, not on pc9821_system's net: that
    // net reaches pc9821_memory_subsystem through an output port, and IEEE 1800-2017 23.3.3.7
    // makes both sides one net, but Verilator keeps them apart unless it inlines the module,
    // so a force on the outer net left the subsystem's own copy at 0 (its open bus, windows
    // and PEGC held in reset) under 5.054, which inlines after scoping. A force on the
    // variable reaches every reader through the port assigns under any inlining.
    force dut.memory.loader.cpu_run = 1'b1;
    force dut.z_inta = 1'b0;
    force dut.z_io = 1'b1;
    force dut.z_valid = valid_on;
    force dut.z_addr = cpu_addr;
    force dut.z_be = cpu_be;
    force dut.z_write = cpu_write;
    force dut.z_dout = cpu_din;
  end

  // The line receiver: 8N1, LSB first, sampled mid-bit, for the whole run.
  reg  [7:0]  stream [0:1023];
  integer     stream_len = 0;
  integer     k;
  reg  [7:0]  rx_byte;
  initial begin : rx_loop
    wait (!reset);
    repeat (2) @(posedge clk_sys);
    forever begin
      while (mpu_line !== 1'b0) @(posedge clk_sys);
      repeat (BIT_CYCLES + BIT_CYCLES/2) @(posedge clk_sys);
      for (k = 0; k < 8; k = k + 1) begin
        rx_byte[k] = mpu_line;
        repeat (BIT_CYCLES) @(posedge clk_sys);
      end
      if (mpu_line !== 1'b1) begin
        $display("FAIL: framing error (no stop bit) after byte %0d", stream_len);
        errors = errors + 1;
      end
      if (stream_len < 1024) stream[stream_len] = rx_byte;
      stream_len = stream_len + 1;
      while (mpu_line !== 1'b1) @(posedge clk_sys);
    end
  end

  task automatic fail(input string message);
    begin
      $display("FAIL: %s", message);
      errors = errors + 1;
    end
  endtask

  task automatic io_byte(input [15:0] port, input bit wr, input [7:0] wdata, output [7:0] rdata);
    integer waited;
    reg [31:0] got;
    begin
      @(negedge clk_sys);
      cpu_addr = {16'd0, port[15:2]};
      cpu_be = 4'b0001 << port[1:0];
      cpu_write = wr;
      cpu_din = 32'd0;
      cpu_din[{port[1:0], 3'b000} +: 8] = wdata;
      valid_on = 1'b1;
      waited = 0;
      while (!dut.io_cpu_ready) begin
        @(negedge clk_sys);
        waited = waited + 1;
        if (waited > 5000) $fatal(1, "TB_PC9821_MPU_PROBE: FAIL - an I/O access to %04x never completed", port);
      end
      got = dut.io_cpu_dout;
      rdata = got[{port[1:0], 3'b000} +: 8];
      @(negedge clk_sys);
      valid_on = 1'b0; cpu_be = 4'd0; cpu_write = 1'b0;
      repeat (4) @(negedge clk_sys);
    end
  endtask

  // MPUTEST's wait_ready: poll status until BUSY (bit 6) is clear. Bounded like the probe's
  // 200 ms ARTIC deadline (10 M clk_sys at 50 MHz).
  task automatic wait_ready(output bit timed_out);
    reg [7:0] st;
    integer polls;
    begin
      polls = 0;
      timed_out = 1'b0;
      io_byte(16'hE0D2, 1'b0, 8'h00, st);
      while (st[6]) begin
        polls = polls + 1;
        if (polls > 1_000_000) begin timed_out = 1'b1; break; end
        io_byte(16'hE0D2, 1'b0, 8'h00, st);
      end
    end
  endtask

  integer cmd_idx = 0;
  // The ACK expected for a command beyond the /BYTES script (the blind-burst sections below),
  // set by the caller from the same rule the script's MPUTEST_ACK encodes.
  bit extra_ack = 1'b1;

  // MPUTEST's do_cmd: ready, write the command, wait (bounded) for status bit 7 to clear,
  // read the data port, drain whatever else is queued.
  task automatic do_cmd(input [7:0] c);
    reg [7:0] st, d;
    bit to;
    integer polls, extra;
    begin
      wait_ready(to);
      if (to) fail($sformatf("BUSY never cleared before command %02x", c));
      io_byte(16'hE0D2, 1'b1, c, d);
      polls = 0;
      io_byte(16'hE0D2, 1'b0, 8'h00, st);
      while (st[7] && polls < 20_000) begin
        polls = polls + 1;
        io_byte(16'hE0D2, 1'b0, 8'h00, st);
      end
      if (!st[7]) begin
        io_byte(16'hE0D0, 1'b0, 8'h00, d);
        extra = 0;
        io_byte(16'hE0D2, 1'b0, 8'h00, st);
        while (!st[7] && extra < 64) begin
          io_byte(16'hE0D0, 1'b0, 8'h00, st);
          extra = extra + 1;
          io_byte(16'hE0D2, 1'b0, 8'h00, st);
        end
        $display("  CMD %02x ack=%02x polls=%0d extra=%0d", c, d, polls, extra);
        if ((cmd_idx < MPUTEST_CMD_N) ? !MPUTEST_ACK[cmd_idx] : !extra_ack) fail($sformatf("command %02x ACKed; the reference does not ACK it", c));
        else if (d !== 8'hFE) fail($sformatf("command %02x answered %02x, want the ACK FE", c, d));
        if (extra != 0) fail($sformatf("command %02x left %0d further byte(s) queued", c, extra));
      end
      else begin
        $display("  CMD %02x ack=-- (no answer)", c);
        if ((cmd_idx < MPUTEST_CMD_N) ? MPUTEST_ACK[cmd_idx] : extra_ack) fail($sformatf("command %02x was not ACKed", c));
      end
      cmd_idx = cmd_idx + 1;
    end
  endtask

  task automatic do_data(input [7:0] b);
    reg [7:0] d;
    bit to;
    begin
      wait_ready(to);
      if (to) fail($sformatf("BUSY never cleared before data byte %02x", b));
      io_byte(16'hE0D0, 1'b1, b, d);
    end
  endtask

  // ==== CHECKS ====
  integer pc, n, j, q, base, idle, raw_got, raw_start;
  reg [7:0] d8;
  initial begin
    repeat (8) @(negedge clk_sys);
    reset = 0;
    repeat (200) @(negedge clk_sys);

    // (1) the /BYTES script, op by op
    pc = 0;
    while (pc < MPUTEST_OPS_N && MPUTEST_OPS[pc] != 8'h00) begin
      case (MPUTEST_OPS[pc])
        8'h01: begin do_cmd(MPUTEST_OPS[pc+1]); pc = pc + 2; end
        8'h02: begin
          n = MPUTEST_OPS[pc+1];
          for (j = 0; j < n; j = j + 1) do_data(MPUTEST_OPS[pc+2+j]);
          pc = pc + 2 + n;
        end
        8'h03: pc = pc + 3;                 // WAIT: time only, no bytes
        8'h04: begin                         // LABEL: skip to the '$'
          pc = pc + 1;
          while (MPUTEST_OPS[pc] != 8'h24) pc = pc + 1;
          pc = pc + 1;
        end
        default: $fatal(1, "TB_PC9821_MPU_PROBE: FAIL - op %02x at %0d is not in /BYTES", MPUTEST_OPS[pc], pc);
      endcase
    end
    if (cmd_idx != MPUTEST_CMD_N) fail($sformatf("ran %0d commands, the script has %0d", cmd_idx, MPUTEST_CMD_N));
    // drain the line: done when no new byte has started for 4 byte times
    idle = 0;
    base = stream_len;
    while (idle < 4 * 10 * BIT_CYCLES) begin
      @(negedge clk_sys);
      if (stream_len != base) begin base = stream_len; idle = 0; end
      else idle = idle + 1;
    end
    $display("  /BYTES: %0d bytes on the line, %0d expected", stream_len, MPUTEST_WIRE_N);
    if (stream_len != MPUTEST_WIRE_N)
      fail($sformatf("/BYTES put %0d bytes on the line, the reference %0d", stream_len, MPUTEST_WIRE_N));
    for (j = 0; j < MPUTEST_WIRE_N && j < stream_len; j = j + 1)
      if (stream[j] !== MPUTEST_WIRE[j]) begin
        fail($sformatf("wire byte %0d is %02x, the reference %02x", j, stream[j], MPUTEST_WIRE[j]));
        for (q = (j > 8 ? j - 8 : 0); q < j + 16 && q < stream_len; q = q + 1)
          $display("    byte %0d: line %02x reference %02x", q, stream[q],
                   (q < MPUTEST_WIRE_N) ? MPUTEST_WIRE[q] : 8'hxx);
        break;
      end

    // (2) the blind burst written at once after 0x3F, while its all-notes-off burst is still
    //     going out, and (3) the probe's /RAW: the same 200 bytes once that burst has drained.
    //     Both REPORTED: how many of F0 7D d.. F7 reached the line.
    for (q = 0; q < 2; q = q + 1) begin
      extra_ack = 1'b1;                        // 0x3F: an intelligent-mode command, ACKed
      do_cmd(8'h3F);
      raw_start = stream_len + 48;             // past the 3F burst
      if (q == 1) repeat (5_000_000) @(negedge clk_sys);   // 100 ms, as the probe waits
      for (j = 0; j < 200; j = j + 1)
        io_byte(16'hE0D0, 1'b1, (j == 0) ? 8'hF0 : (j == 1) ? 8'h7D : (j == 199) ? 8'hF7 : 8'((j - 2) & 8'h7F), d8);
      idle = 0;
      base = stream_len;
      while (idle < 4 * 10 * BIT_CYCLES) begin
        @(negedge clk_sys);
        if (stream_len != base) begin base = stream_len; idle = 0; end
        else idle = idle + 1;
      end
      raw_got = stream_len - raw_start;
      $display("  REPORT RAW %s: 200 bytes written blind in UART mode, %0d reached the line%s",
               (q == 0) ? "during the 0x3F burst" : "100 ms after 0x3F (MPUTEST /RAW)", raw_got,
               (raw_got > 0 && stream[stream_len-1] == 8'hF7) ? " (the closing F7 among them)" : "");
      extra_ack = 1'b0;                        // 0xFF leaving UART mode: no ACK (the manual)
      do_cmd(8'hFF);
    end

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_MPU_PROBE: FAIL - %0d check(s) failed", errors);
    $display("TB_PC9821_MPU_PROBE: PASS");
    $finish;
  end

  initial begin
    #1_000_000_000;
    $fatal(1, "TB_PC9821_MPU_PROBE: TIMEOUT");
  end
endmodule

`default_nettype wire
