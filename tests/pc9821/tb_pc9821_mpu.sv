`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_MPU: The MPU-PC98II register model answers the read side the driver hangs on (idle status 0x80, the ACK 0xFE per command with bit 7 clearing while it is queued, the data register's last-read latch), raises one IRQ edge per response byte (an enqueue onto a non-empty queue and a read that leaves a byte each re-raise, the drain does not), frames the intelligent-mode transfers it receives (0xD0 + 3 bytes emitted as one complete 0x90 40 7F message, a 0xD0 message sent under running status without its status byte re-emitted with the full status byte as 0x91 3C 00, 0xDF + F0..F7 byte-identically), emits the 0xFF reset's 16-channel all-notes-off burst in order, produces no MIDI bytes for a follow-byte command, enters UART mode on 0x3F and leaves it on 0xFF with no ACK (the MPU-401 manual's one unacknowledged command: status bit 7 stays set, no request, no byte on the line) while the next intelligent-mode command is ACKed, raises the H.CLK 0xFD after 0x95, and loses no byte from a writer that polls BUSY (status bit 6, the MPU-401's DRR) before every write - every byte reaches the line in order across the 0x3F burst, the 32-byte queue filling and a 63-byte 0xDF system exclusive behind the 0xFF burst, and BUSY reads set whenever a byte is parked waiting for room - all at the real 31250-baud line rate, which a two-clock probe measures as the SAME 32 us bit time and 320 us byte time at 50 and 100 MHz.
//
// The expected values are the reference's, not this RTL's: NP2kai's model
// (../NP2kai/cbus/mpu98ii.c at 5939e0c) for the status polarity (:1129-1131 `if ((mpu98.r.cnt
// == 0) && (mpu98.intreq == 0)) { ret |= MIDIIN_AVAIL;`), the ACK (:1054
// `setrecvdata(MPUMSG_ACK);`), the short message's framing and length table (:124-125
// `shortmsgleng`, sendmpumsg :797-822), the system-exclusive framing (:823-854), the reset
// burst (sendmpureset :247-258), the H.CLK tick and its stepclock (makeintclock :135-153,
// midiint :353-376, mpucmd_9x case 0x05 :552-557), and the register defaults (:1178
// `mpu98.data = MPUMSG_ACK;`); the Roland MPU-401 Technical Reference Manual's DRR handshake
// for the polled writer (section 13); and MMD.COM's own primitives for what
// the driver polls (CS:0x01C6 read, CS:0x01D3 write, CS:0x15AC presence probe, CS:0x167E H.CLK
// wait), every one of them read from the driver's disassembly.
//
// FAIL-FIRST, class by class: with the read-back replaced by a tie-off (the shape pc9821_iobus
// gives an undecoded port) the idle-status check reads 0xFF and the driver's `test al,al / js`
// loop never exits; with the message assembly removed the 0x90 40 7F check sees three separate
// bytes instead of one message; with the reset burst removed the 48-byte check sees zero; with
// the H.CLK arm removed the 0xFD check times out; with the running-status data byte left at
// index 1 instead of advancing to 2 (the pre-fix core) the second 0x91 3C 00 never reaches the
// line; with BUSY taken from the queue count alone (the pre-fix core) the 0x3F burst's first
// cycles read BUSY clear while a byte is parked, and the polled UART-mode writer's bytes are
// overwritten there; and with the serialiser's divider taken from
// a fixed clk_sys count instead of SYS_CLOCK_HZ the 100 MHz probe's bit time halves.

module tb_pc9821_mpu;

  // ==== DUT ====
  localparam integer BIT_CYCLES = 1600;          // 50_000_000 / 31250, exact at every profile clock

  reg         clk = 1'b0;
  reg         clk100 = 1'b0;
  reg         reset = 1'b1;
  always #10 clk = ~clk;                          // 50 MHz (the base profile)
  always #5  clk100 = ~clk100;                    // 100 MHz (mediumoc)

  reg         cs = 1'b0;
  reg  [15:0] addr = 16'hE0D0;
  reg         wr = 1'b0;
  reg         rd = 1'b0;
  reg  [7:0]  din = 8'h00;
  wire [7:0]  dout;
  wire        uart_tx;
  wire        irq;

  pc9821_mpu #(.SYS_CLOCK_HZ(50_000_000)) dut (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr), .wr(wr), .rd(rd),
      .din(din), .dout(dout), .uart_tx(uart_tx), .irq(irq));

  // The line receiver: every byte the DUT puts on the wire, decoded at 8N1 LSB-first by
  // sampling the middle of each bit. It runs for the whole test, so a byte that appears EARLY
  // (before a message is complete, or at all when the command should be silent) is caught
  // rather than reasoned about.
  reg  [7:0]  stream [0:255];
  integer     stream_len = 0;
  integer     k;
  reg  [7:0]  rx_byte;

  initial begin : rx_loop
    // The line is only meaningful once the reset has been released: before that the
    // transmitter's power-up mark has not been applied and a zero would read as a start bit.
    wait (!reset);
    repeat (2) @(posedge clk);
    forever begin
      while (uart_tx !== 1'b0) @(posedge clk);   // the start bit's falling edge
      repeat (BIT_CYCLES + BIT_CYCLES/2) @(posedge clk);
      for (k = 0; k < 8; k = k + 1) begin
        rx_byte[k] = uart_tx;
        repeat (BIT_CYCLES) @(posedge clk);
      end
      if (stream_len < 256) begin
        stream[stream_len] = rx_byte;
        stream_len = stream_len + 1;
      end
      // The stop bit: wait for the mark instead of counting one more bit time, so a byte
      // that follows with a SHORT gap is still found by its own start edge rather than
      // missed while this receiver was still timing the previous byte out.
      while (uart_tx !== 1'b1) @(posedge clk);
    end
  end

  // ==== CHECKS ====
  integer errors = 0;

  task automatic chk(input condition, input string msg);
    begin
      if (!condition) begin
        errors = errors + 1;
        $display("FAIL %s", msg);
        $fatal(1, "MPU check failed: %s", msg);
      end
    end
  endtask

  // One device strobe, exactly as pc9821_iobus presents it: cs and the address are held for one
  // clk_sys while the one-cycle S_BYTE strobe is high.
  // The stimulus is driven from the NEGEDGE, so the DUT's posedge always samples the strobe
  // and there is no race between this bench and the DUT about which edge sees it.
  task automatic bus_wr(input [15:0] a, input [7:0] b);
    begin
      @(negedge clk);
      cs = 1'b1; addr = a; din = b; wr = 1'b1; rd = 1'b0;
      @(negedge clk);
      wr = 1'b0; cs = 1'b0;
    end
  endtask

  // A read samples the byte combinationally (pc9821_system's device read mux takes it in the
  // strobe cycle), and the DATA port's pop happens on the strobe's clk edge.
  task automatic bus_rd(input [15:0] a, output [7:0] b);
    begin
      @(negedge clk);
      cs = 1'b1; addr = a; rd = 1'b1; wr = 1'b0;
      #1;
      b = dout;
      @(negedge clk);
      rd = 1'b0; cs = 1'b0;
    end
  endtask

  task automatic idle_cycles(input integer n);
    integer j;
    begin
      for (j = 0; j < n; j = j + 1) @(posedge clk);
    end
  endtask

  // MMD's write primitive (CS:0x01D3 `in al,0xE0D2 / test al,0x40 / jnz`): read the status
  // until BUSY (bit 6) is clear. Every status read also checks the one property a polling
  // writer relies on: a byte parked outside the MIDI-out queue reads as BUSY. The park flag is
  // sampled at the same instant as the status byte.
  integer parked_polls = 0;
  task automatic poll_ready;
    reg [7:0] st;
    reg       parked;
    integer   n;
    begin
      n = 0;
      st = 8'h40;
      while (st[6]) begin
        @(negedge clk);
        cs = 1'b1; addr = 16'hE0D2; rd = 1'b1; wr = 1'b0;
        #1;
        st = dout;
        parked = dut.pend_valid;
        @(negedge clk);
        rd = 1'b0; cs = 1'b0;
        if (parked) parked_polls = parked_polls + 1;
        chk(!parked || st[6],
            "BUSY (status bit 6) reads clear while a byte is parked waiting for room");
        n = n + 1;
        chk(n < 2_000_000, "BUSY never cleared for a polling writer");
      end
    end
  endtask

  // A polled command: wait for BUSY clear, write it, then take every response byte queued
  // (the ACK; MMD reads it before the next write).
  task automatic polled_cmd(input [7:0] c);
    reg [7:0] st, d;
    begin
      poll_ready();
      bus_wr(16'hE0D2, c);
      bus_rd(16'hE0D2, st);
      chk(st[7] == 1'b0, "a polled command was not ACKed");
      while (!st[7]) begin
        bus_rd(16'hE0D0, d);
        bus_rd(16'hE0D2, st);
      end
    end
  endtask

  // The UART-mode exit: 0xFF written BUSY-polled, which the MPU-401 does not acknowledge
  // (section 10a), so nothing is waited for or drained.
  task automatic polled_uart_exit;
    begin
      poll_ready();
      bus_wr(16'hE0D2, 8'hFF);
    end
  endtask

  task automatic polled_dat(input [7:0] b);
    begin
      poll_ready();
      bus_wr(16'hE0D0, b);
    end
  endtask

  // Done when no new byte has started on the line for four byte times.
  task automatic wait_line_idle;
    integer idle, base;
    begin
      idle = 0;
      base = stream_len;
      while (idle < 4 * 10 * BIT_CYCLES) begin
        @(posedge clk);
        if (stream_len != base) begin base = stream_len; idle = 0; end
        else idle = idle + 1;
      end
    end
  endtask

  reg [7:0] b0, b1;
  integer   t0;

  // The PIC is an edge latch (pc9821_pic.sv ir_set = ir_in & ~ir_prev): what reaches the guest is
  // one request per RISING edge of the line, so that is what this counter measures.
  reg       irq_q = 1'b0;
  integer   irq_rises = 0;
  always @(posedge clk) begin
    irq_q <= irq;
    if (irq && !irq_q) irq_rises <= irq_rises + 1;
  end

  wire [31:0] rate50_bit_ns, rate100_bit_ns;

  initial begin
    fork
      // A bench that stops making progress names itself instead of hanging the runner.
      // 400 ms of simulated time covers every burst and tick this bench waits for.
      begin
        #400_000_000;
        $fatal(1, "tb_pc9821_mpu did not finish in 400 ms of simulated time");
      end
      begin
        reset = 1'b1;
        idle_cycles(20);
        reset = 1'b0;
        idle_cycles(20);

        // ---- 1. the idle read-back: status 0x80, data 0xFE, no IRQ -------------------
        bus_rd(16'hE0D2, b0);
        chk(b0 == 8'h80, "idle status is not 0x80 (bit 7 = response register empty)");
        chk(irq == 1'b0, "IRQ asserted with an empty response queue");
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "the data register of an empty queue does not return the latch");

        // ---- 2. MMD's presence probe: (rd(0xE0D0) & rd(0xE0D2)) != 0xFF --------------
        bus_rd(16'hE0D0, b0);
        bus_rd(16'hE0D2, b1);
        chk((b0 & b1) != 8'hFF, "the presence probe's AND reads all ones: no board");

        // ---- 3. every command queues an ACK, and bit 7 clears while it is queued ------
        bus_wr(16'hE0D2, 8'h94);            // clock to host OFF
        bus_rd(16'hE0D2, b0);
        chk(b0[7] == 1'b0, "status bit 7 stayed set with an ACK queued");
        chk(irq == 1'b1, "IRQ not asserted with an ACK queued");
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "the ACK is not 0xFE");
        bus_rd(16'hE0D2, b0);
        chk(b0 == 8'h80, "status did not return to 0x80 after the queue drained");
        chk(irq == 1'b0, "IRQ stayed asserted after the queue drained");

        // ---- 4. 0xE7 + 0x04: ACKed, and NOTHING reaches the line ---------------------
        stream_len = 0;
        bus_wr(16'hE0D2, 8'hE7);
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "0xE7 was not ACKed");
        bus_wr(16'hE0D0, 8'h04);
        idle_cycles(100_000);               // 2 ms, six byte times
        chk(stream_len == 0, "a follow-byte command put bytes on the MIDI line");

        // ---- 5. 0xD0 + 90 40 7F: exactly one complete message, and only at completion -
        stream_len = 0;
        bus_wr(16'hE0D2, 8'hD0);
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "0xD0 was not ACKed");
        bus_wr(16'hE0D0, 8'h90);
        bus_wr(16'hE0D0, 8'h40);
        idle_cycles(100_000);
        chk(stream_len == 0, "an incomplete short message reached the line");
        bus_wr(16'hE0D0, 8'h7F);
        idle_cycles(60_000);                // ~1.2 ms: three byte times
        chk(stream_len == 3, "the completed short message did not put exactly 3 bytes out");
        chk(stream[0] == 8'h90, "short message byte 0 is wrong");
        chk(stream[1] == 8'h40, "short message byte 1 is wrong");
        chk(stream[2] == 8'h7F, "short message byte 2 is wrong");

        // ---- 5b. 0xD0 under running status: the status byte is re-emitted -------------
        // 0xD0, 91 3C 40 (a full message), then 0xD0, 3C 00 (no status byte). NP2kai's
        // sendmpumsg (../NP2kai/cbus/mpu98ii.c at 5939e0c) stores the running status at the
        // first message (:809 `cmd->rstat = data;`), puts it at index 0 of the second
        // (:803 `cmd->data[0] = cmd->rstat;`, :804 `cmd->datapos = 1;`), stores 3C at index 1
        // and advances to 2 (:816 `cmd->datapos++;`), so 00 completes it and
        // sendmpushortmsg puts all three bytes out: the line carries 91 3C 40 91 3C 00. NP2kai's
        // own MIDI-OUT file from MPUTEST /BYTES holds the same six bytes (the mputest lane's
        // cross-check). The wire carries the full status again: sendmpushortmsg writes every
        // byte it is handed (:230-231 `cm->write(cm, dat[i]);`), with no running-status
        // compression on the way out.
        stream_len = 0;
        bus_wr(16'hE0D2, 8'hD0);
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "the first 0xD0 of the running-status pair was not ACKed");
        bus_wr(16'hE0D0, 8'h91);
        bus_wr(16'hE0D0, 8'h3C);
        bus_wr(16'hE0D0, 8'h40);
        bus_wr(16'hE0D2, 8'hD0);
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "the second 0xD0 of the running-status pair was not ACKed");
        bus_wr(16'hE0D0, 8'h3C);
        bus_wr(16'hE0D0, 8'h00);
        idle_cycles(120_000);               // ~2.4 ms: six byte times
        chk(stream_len == 6, "0xD0 + a running-status message did not put 6 bytes out");
        chk(stream[0] == 8'h91 && stream[1] == 8'h3C && stream[2] == 8'h40,
            "the full message before the running-status one is wrong");
        chk(stream[3] == 8'h91, "the running-status message did not re-emit its status 0x91");
        chk(stream[4] == 8'h3C, "the running-status message's note is not 0x3C");
        chk(stream[5] == 8'h00, "the running-status message's velocity is not 0x00");

        // ---- 6. 0xDF + a system exclusive passes through byte-identically --------------
        stream_len = 0;
        bus_wr(16'hE0D2, 8'hDF);
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "0xDF was not ACKed");
        bus_wr(16'hE0D0, 8'hF0);
        bus_wr(16'hE0D0, 8'h43);
        bus_wr(16'hE0D0, 8'h75);
        bus_wr(16'hE0D0, 8'h00);
        bus_wr(16'hE0D0, 8'h01);
        bus_wr(16'hE0D0, 8'hF7);
        idle_cycles(100_000);
        chk(stream_len == 6, "the system exclusive put the wrong number of bytes out");
        chk(stream[0] == 8'hF0 && stream[1] == 8'h43 && stream[2] == 8'h75 &&
            stream[3] == 8'h00 && stream[4] == 8'h01 && stream[5] == 8'hF7,
            "the system exclusive is not byte-identical");

        // ---- 7. 0x95: the H.CLK byte the driver's connection check waits for ----------
        bus_wr(16'hE0D2, 8'h95);
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "0x95 was not ACKed");
        bus_rd(16'hE0D2, b0);
        chk(b0[7] == 1'b0, "no H.CLK byte in the response queue after 0x95");
        chk(irq == 1'b1, "IRQ not asserted for the H.CLK byte");
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFD, "the H.CLK byte is not 0xFD");
        // It repeats at the reference's stepclock, SYS_CLOCK_HZ/200 = 5 ms (250_000 cycles).
        t0 = 0;
        while (irq == 1'b0 && t0 < 600_000) begin
          @(posedge clk);
          t0 = t0 + 1;
        end
        chk(irq == 1'b1, "the H.CLK tick did not repeat within 12 ms");
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFD, "the repeated H.CLK byte is not 0xFD");
        chk((t0 > 200_000) && (t0 < 300_000),
            "the H.CLK period is not the reference's stepclock (250_000 cycles)");

        // ---- 8. 0x94 turns it off again ----------------------------------------------
        bus_wr(16'hE0D2, 8'h94);
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "0x94 was not ACKed");
        idle_cycles(600_000);               // 12 ms: two stepclocks
        bus_rd(16'hE0D2, b0);
        chk(b0 == 8'h80, "the H.CLK tick continued after 0x94");

        // ---- 9. BUSY (status bit 6) is the output credit -----------------------------
        bus_rd(16'hE0D2, b0);
        chk(b0[6] == 1'b0, "BUSY is set with an idle output queue");
        stream_len = 0;
        bus_wr(16'hE0D2, 8'hFF);            // reset: the 48-byte all-notes-off burst
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "0xFF was not ACKed");
        idle_cycles(1000);
        bus_rd(16'hE0D2, b0);
        chk(b0[6] == 1'b1, "BUSY is clear while the 48-byte reset burst is outstanding");
        idle_cycles(900_000);               // 18 ms: 48 byte times is 15.4 ms
        bus_rd(16'hE0D2, b0);
        chk(b0[6] == 1'b0, "BUSY stayed set after the reset burst drained");
        chk(stream_len == 48, "the reset did not put 48 bytes on the line");
        begin : burst_chk
          integer i;
          for (i = 0; i < 16; i = i + 1) begin
            chk(stream[i*3 + 0] == (8'hB0 + i[7:0]), "the reset burst's channel status is wrong");
            chk(stream[i*3 + 1] == 8'h7B, "the reset burst's controller byte is not 0x7B");
            chk(stream[i*3 + 2] == 8'h00, "the reset burst's value byte is not 0x00");
          end
        end

        // ---- 10. 0x3F: UART mode, and a data write passes straight through ------------
        stream_len = 0;
        bus_wr(16'hE0D2, 8'h3F);
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "0x3F was not ACKed");
        idle_cycles(900_000);               // drain the burst 0x3F also sends
        chk(stream_len == 48, "UART mode did not send the all-notes-off burst");
        stream_len = 0;
        bus_wr(16'hE0D0, 8'h5A);
        idle_cycles(60_000);
        chk(stream_len == 1 && stream[0] == 8'h5A,
            "a UART-mode data write did not pass straight through");
        // A command that is not 0xFF is NOT ACKed in UART mode (mpu98ii_o2's mode branch).
        bus_wr(16'hE0D2, 8'h94);
        bus_rd(16'hE0D2, b0);
        chk(b0 == 8'h80, "a command was ACKed in UART mode");
        // ---- 10a. 0xFF leaves UART mode and is NOT acknowledged (todo item 173) ---------
        // The Roland MPU-401 Technical Reference Manual, section 5.3 ($3F): "To return from
        // this mode back to normal MPU-401 operation use the SYSTEM RESET command ($FF). The
        // MPU-401 will not return an ACK ($FE) in this one case."; section 4.1 repeats it: "An
        // ACK will not be sent back upon sending a SYSTEM RESET to leave the UART MODE ($3F)."
        // DOSBox-X agrees (src/hardware/mpu401.cpp, MPU401_WriteCommand case 0xff:
        // `return;	//do not send ack in UART mode`), and a real MPU-PC98 does not ACK it
        // (docs/probes/MPUTEST-XE10.TXT and MPUTEST-XE10-BYTES.TXT: every UART-mode 0xFF row
        // reads `ack=--`, 4 of 4). NP2kai
        // ACKs it; the owner follows the manual and the hardware. So: no data byte becomes
        // readable (status bit 7, DSR, stays 1), no request is raised, no byte reaches the line
        // (no burst from UART mode), and the card is back in intelligent mode, where the next
        // command is ACKed as before.
        stream_len = 0;
        t0 = irq_rises;
        bus_wr(16'hE0D2, 8'hFF);
        idle_cycles(2000);
        bus_rd(16'hE0D2, b0);
        chk(b0 == 8'h80, "0xFF leaving UART mode was acknowledged (status bit 7 cleared)");
        chk(irq == 1'b0 && irq_rises == t0,
            "0xFF leaving UART mode raised a request (an ACK was queued)");
        chk(dut.rq_cnt == 5'd0, "0xFF leaving UART mode queued a response byte");
        idle_cycles(60_000);
        chk(stream_len == 0, "0xFF leaving UART mode put bytes on the line");
        bus_wr(16'hE0D2, 8'h94);            // intelligent mode again: ACKed as before
        bus_rd(16'hE0D2, b0);
        chk(b0 == 8'h00, "the command after leaving UART mode was not ACKed (still in UART mode?)");
        chk(irq_rises == t0 + 1, "the intelligent-mode ACK after leaving UART mode raised no request");
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "the intelligent-mode ACK after leaving UART mode is not 0xFE");
        bus_rd(16'hE0D2, b0);
        chk(b0 == 8'h80, "a byte other than the one ACK followed the intelligent-mode command");

        // ---- 10b. the response queue holds two values: ACK 0xFE and H.CLK 0xFD, and ---
        // ----      an ACK outranks a tick when both land on the same cycle --------------
        // Order 1 (H.CLK first, then ACK): 0x95 queues its own ACK and arms the immediate
        // kick, so the queue reads 0xFE then the kick's 0xFD; after one stepclock the periodic
        // H.CLK 0xFD arrives with no ACK ahead of it, and a 0x94 ACK queues BEHIND it.
        bus_wr(16'hE0D2, 8'h95);
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "0x95's own ACK is not 0xFE");
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFD, "the 0x95 kick's H.CLK is not 0xFD");
        t0 = 0;
        while (irq == 1'b0 && t0 < 600_000) begin
          @(posedge clk);
          t0 = t0 + 1;
        end
        chk(irq == 1'b1, "the periodic H.CLK tick did not arrive within 12 ms");
        bus_wr(16'hE0D2, 8'h94);
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFD, "the H.CLK queued ahead of the ACK is not 0xFD");
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "the ACK queued behind the H.CLK is not 0xFE");

        // Order 2 (same cycle): 0x95 arms the kick; the next command's strobe lands on the
        // kick's own cycle, so the ACK and the tick coincide. The ACK must win and the tick be
        // dropped - exactly two 0xFE bytes, no 0xFD.
        bus_wr(16'hE0D2, 8'h95);
        cs = 1'b1; addr = 16'hE0D2; din = 8'h94; wr = 1'b1; rd = 1'b0;
        @(negedge clk);
        wr = 1'b0; cs = 1'b0;
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "the same-cycle ACK did not outrank the H.CLK kick (first byte)");
        bus_rd(16'hE0D0, b0);
        chk(b0 == 8'hFE, "the same-cycle ACK did not outrank the H.CLK kick (second byte)");
        bus_rd(16'hE0D2, b0);
        chk(b0 == 8'h80, "the dropped H.CLK kick left a byte behind the two ACKs");

        // ---- 12. one request per response byte (NP2kai mpu98ii.c:1101-1102 re-raises after a
        //         read that leaves a byte; :1054-1059 raises on every ACK enqueue) -------------
        // An ISR that reads ONE byte per interrupt must be interrupted again for the next one.
        idle_cycles(4);
        t0 = irq_rises;
        bus_wr(16'hE0D2, 8'h94);            // ACK 1: the line rises from an empty queue
        idle_cycles(4);
        chk(irq_rises == t0 + 1, "the first ACK raised no request");
        bus_wr(16'hE0D2, 8'h94);            // ACK 2 onto a non-empty queue: a fresh request
        idle_cycles(4);
        chk(irq_rises == t0 + 2, "an ACK queued behind another raised no new request");
        bus_rd(16'hE0D0, b0);               // one byte read, one still queued: a fresh request
        idle_cycles(4);
        chk(b0 == 8'hFE, "the first queued ACK is not 0xFE");
        chk(irq == 1'b1, "the line is low with a byte still queued");
        chk(irq_rises == t0 + 3, "a read that left a byte queued raised no new request");
        bus_rd(16'hE0D0, b0);               // the last byte: the line falls, no request
        idle_cycles(4);
        chk(b0 == 8'hFE, "the second queued ACK is not 0xFE");
        chk(irq == 1'b0, "the line stayed high after the queue drained");
        chk(irq_rises == t0 + 3, "the draining read raised a request");

        // ---- 13. a writer that polls BUSY before every write never loses a byte --------
        // The Roland MPU-401 Technical Reference Manual (CPU v1.5A, Manual v1.5; status port
        // "bit 6 : DRR*", "DRR bit 6 of MPU status byte (Data Receive Ready, active low)", and
        // the section 9A handshake "1. test DRR (bit 6) of STATPORT. 2. if bit 6 = 1, then goto
        // step 1.") gives the host one flow control: bit 6 clear means the card takes the next
        // byte. So a write made with bit 6 clear must never be lost. NP2kai never drops one
        // (../NP2kai/cbus/mpu98ii.c at 5939e0c: mpu98ii_o0's UART branch :1028
        // `sent = cm_mpu98->write(cm_mpu98, (UINT8)dat);` hands each byte on, and the status
        // read :1128 `ret = mpu98.status;` reports MIDIOUT_BUSY as midiwait :399-400 set it).
        // The writer below is MMD's CS:0x01D3 primitive at this bench's fastest bus rate; at
        // every poll, a byte parked outside the queue (dut.pend_valid) must read as BUSY.
        //
        // 13a, UART mode: 0x3F starts the 48-byte all-notes-off burst, then 120 bytes are
        // written as fast as BUSY allows - into the burst's first cycles, while the 32-byte
        // queue fills, and on after it has drained. The line must carry the burst and then all
        // 120 bytes in order. FAIL-FIRST: with BUSY taken from the queue count alone, the
        // writes in the burst's first 16 cycles overwrite the parked byte.
        stream_len = 0;
        polled_cmd(8'h3F);
        for (t0 = 0; t0 < 120; t0 = t0 + 1) polled_dat(t0[7:0]);
        wait_line_idle();
        chk(stream_len == 48 + 120,
            "a BUSY-polled UART-mode writer lost or gained bytes across the 0x3F burst");
        for (t0 = 0; t0 < 48; t0 = t0 + 1)
          chk(stream[t0] == ((t0 % 3 == 0) ? (8'hB0 + 8'(t0 / 3)) :
                             (t0 % 3 == 1) ? 8'h7B : 8'h00),
              "the 0x3F burst is not 16 x Bn 7B 00 ahead of the polled bytes");
        for (t0 = 0; t0 < 120 && 48 + t0 < stream_len; t0 = t0 + 1)
          chk(stream[48 + t0] == t0[7:0],
              "a BUSY-polled UART-mode byte is missing or out of order");
        polled_uart_exit();                 // back to intelligent mode (no burst, no ACK)
        wait_line_idle();

        // 13b, intelligent mode: 0xFF's burst, then 0xDF and a 63-byte system exclusive
        // (F0 7D 00..3B F7) written BUSY-polled, longer than the queue. Same invariant.
        stream_len = 0;
        polled_cmd(8'hFF);
        polled_cmd(8'hDF);
        polled_dat(8'hF0);
        polled_dat(8'h7D);
        for (t0 = 0; t0 < 60; t0 = t0 + 1) polled_dat(t0[7:0]);
        polled_dat(8'hF7);
        wait_line_idle();
        chk(stream_len == 48 + 63,
            "a BUSY-polled 0xDF writer lost or gained bytes across the 0xFF burst");
        chk(stream[48] == 8'hF0 && stream[49] == 8'h7D && stream[48 + 62] == 8'hF7,
            "the BUSY-polled system exclusive is not framed F0 7D .. F7 after the burst");
        for (t0 = 0; t0 < 60; t0 = t0 + 1)
          chk(stream[50 + t0] == t0[7:0],
              "a BUSY-polled system exclusive byte is missing or out of order");
        chk(parked_polls > 0,
            "no poll ever met a parked byte: the BUSY-while-parked check never ran");

        // ---- 11. the two-clock line rate ----------------------------------------------
        // The probes run their own DUTs from the same reset; a fixed clk_sys count would read
        // 32 us at 50 MHz and 16 us at 100 MHz.
        t0 = 0;
        while ((rate50_bit_ns == 32'd0 || rate100_bit_ns == 32'd0) && t0 < 2_000_000) begin
          @(posedge clk);
          t0 = t0 + 1;
        end
        chk(t0 < 2_000_000, "the two-clock rate probes did not complete");
        chk(rate50_bit_ns  == 32'd32_000, "the 50 MHz MIDI bit time is not 32 us");
        chk(rate100_bit_ns == 32'd32_000, "the 100 MHz MIDI bit time is not 32 us");

        // ==== VERDICT ====
        $display("TB_PC9821_MPU: PASS");
        $finish;
      end
    join
  end

  tb_mpu_rate_probe #(.HZ(50_000_000)) rate50 (
      .clk(clk), .reset(reset), .bit_ns(rate50_bit_ns));
  tb_mpu_rate_probe #(.HZ(100_000_000)) rate100 (
      .clk(clk100), .reset(reset), .bit_ns(rate100_bit_ns));

endmodule

// ==== THE LINE-RATE PROBE ====
// Drives one channel message into its own pc9821_mpu and measures, in NANOSECONDS, the start
// bit's width - which IS the bit time, 1/31250 s. It is a real time: a divider counting clk_sys
// rather than deriving from SYS_CLOCK_HZ reports half the time at twice the clock.
module tb_mpu_rate_probe #(parameter integer HZ = 50_000_000) (
    input  wire        clk,
    input  wire        reset,
    output reg  [31:0] bit_ns
);
  reg         cs = 1'b0;
  reg  [15:0] addr = 16'hE0D0;
  reg         wr = 1'b0;
  reg         rd = 1'b0;
  reg  [7:0]  din = 8'h00;
  wire [7:0]  dout;
  wire        uart_tx;
  wire        irq;
  integer     c;
  localparam integer NS_PER_CYCLE = 1_000 / (HZ / 1_000_000);

  pc9821_mpu #(.SYS_CLOCK_HZ(HZ)) dut (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr), .wr(wr), .rd(rd),
      .din(din), .dout(dout), .uart_tx(uart_tx), .irq(irq));

  // The stimulus is driven from the NEGEDGE, so the DUT's posedge always samples the strobe
  // and there is no race between this bench and the DUT about which edge sees it.
  task automatic bus_wr(input [15:0] a, input [7:0] b);
    begin
      @(negedge clk);
      cs = 1'b1; addr = a; din = b; wr = 1'b1; rd = 1'b0;
      @(negedge clk);
      wr = 1'b0; cs = 1'b0;
    end
  endtask

  initial begin
    bit_ns = 32'd0;
    wait (!reset);
    repeat (10) @(posedge clk);
    // 0xD0 (command) then 0x91 0x7F 0x7F: one complete channel message reaches the wire. Both
    // bytes have bit 0 SET, so the first low run after the falling edge IS the start bit and
    // nothing else - with a bit 0 of zero the run would continue through the data bits.
    bus_wr(16'hE0D2, 8'hD0);
    bus_wr(16'hE0D0, 8'h91);
    bus_wr(16'hE0D0, 8'h7F);
    bus_wr(16'hE0D0, 8'h7F);
    // The start bit is the first falling edge after the line has idled high.
    while (uart_tx !== 1'b1) @(posedge clk);
    while (uart_tx !== 1'b0) @(posedge clk);
    c = 0;
    while (uart_tx === 1'b0) begin
      @(posedge clk);
      c = c + 1;
    end
    bit_ns = c * NS_PER_CYCLE;      // one clk cycle is NS_PER_CYCLE nanoseconds
  end
endmodule
