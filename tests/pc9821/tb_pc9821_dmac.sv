`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The uPD71071 register file answering the machine's own captured values (the address and count registers readable, 0x11/0x1B/0x29 reading 0x00, the write-only registers driving 0xFF), the ITF self-test shape surviving a real low/high byte flip-flop, and the engine moving bytes in both directions: a programmed count of N+1, the address walking by the mode's direction, terminal count reported on the last byte, the channel masked at terminal count, and the status bits cleared when the status register is read. S7 pins the clear WIDTH: the 0x11 read clears only the terminal-count nibble stat[3:0] and leaves the request-state nibble stat[7:4] standing, exactly NP2kai's dmac_i11 `dmac.stat &= 0xf0` (io/dmac.c:290-294) (FAIL-FIRST against a full-byte clear that eats the nibble).
//
// The uPD71071 register file answering the machine's own captured values (the address and count registers readable, 0x11/0x1B/0x29 reading 0x00, the write-only registers driving 0xFF), the ITF self-test shape surviving a real low/high byte flip-flop, and the engine moving bytes in both directions: a programmed count of N+1, the address walking by the mode's direction, terminal count reported on the last byte, the channel masked at terminal count, and the status bits cleared when the status register is read. Plus S7's clear-WIDTH pin: the 0x11 read clears only the terminal-count nibble stat[3:0] and leaves the request-state nibble stat[7:4] standing, which is exactly what NP2kai's dmac_i11 does (`dmac.stat &= 0xf0`, io/dmac.c:290-294) and exactly what a full-byte clear breaks.
//
// The register cases are the machine's, not the model's. The machine
// captures record what the real machine answers at these ports: the address
// and count registers are readable, 0x11/0x1B/0x29 read 0x00, and
// 0x13/0x15/0x17/0x19/0x1D/0x1F read 0xFF because they are write-only and the
// chip drives that value -- "distinguished by the chip, not by bus float". S3
// pins every one of them, and 0x1B is the one NP2kai itself would float.
//
// S2 pins the shape the authentic ITF's self-test uses (BANK4@0x3E9: write 0xFF,
// read back, write 0x00, read back, "DMA ERROR" and halt on a mismatch). It is
// here because that test currently passes against a stub in pc9821_iobus that
// latched whatever was written, and this bench is what keeps it passing once the
// stub is replaced by a chip with a real low/high flip-flop in it, where the write
// and the read each advance the byte pointer.
//
// S4 is a phase test as well as a transfer test, and that is deliberate: the
// device's data bus advances ONLY when the controller strobes it, so the byte the
// controller latches is the byte that was on the bus during its strobe. If the
// strobe and the sample were a cycle apart -- which they were in an earlier draft
// of this module, where dev_stb was a register -- the sequence lands shifted and
// the memory check below fails. A bench that held the same byte throughout would
// pass either way and would prove nothing about the phase.
//
// FALSIFIABILITY. This module is new, so there is no previous engine to fail
// against; what has to be shown is that each case CAN fail. Two were observed
// failing before being trusted: removing the count decrement in S_FIN makes S4
// report that memory still holds the first byte, and making dev_stb a registered
// strobe makes S4 fail on a shifted sequence. The register cases (S2 onward) fail
// against the stub this replaces for a blunter reason -- it held only the eight
// registers at 0x01..0x0F with a three-bit index, so 0x11 selected past the end of
// its own array and every case from S3 on had nothing to read.

module tb_pc9821_dmac;

  // ==== DUT ====
  reg         clk = 0;
  reg         reset = 1;
  reg         sel = 0, write = 0;
  reg  [4:0]  idx = 0;
  reg  [7:0]  din = 0;
  wire [7:0]  dout;

  reg  [3:0]  drq = 0;
  wire [3:0]  dack;
  wire        dev_we, dev_stb, dev_tc;
  wire [1:0]  dev_ch;
  wire [7:0]  dev_dout;
  reg  [7:0]  dev_din = 8'hA0;

  wire [31:0] mem_addr;
  wire        mem_we;
  wire [3:0]  mem_be;
  wire [31:0] mem_din;
  wire        mem_req;
  reg         mem_ready = 0;
  reg         mem_resp_valid = 0;
  reg  [31:0] mem_dout = 0;

  pc9821_dmac dut (
    .clk(clk), .reset(reset),
    .sel(sel), .write(write), .idx(idx), .din(din), .dout(dout),
    .dev_drq(drq), .dev_dack(dack), .dev_we(dev_we), .dev_stb(dev_stb),
    .dev_tc(dev_tc), .dev_ch(dev_ch), .dev_dout(dev_dout), .dev_din(dev_din),
    .mem_addr(mem_addr), .mem_we(mem_we), .mem_be(mem_be), .mem_din(mem_din),
    .mem_dout(mem_dout), .mem_req(mem_req),
    .mem_ready(mem_ready), .mem_resp_valid(mem_resp_valid)
  );

  always #5 clk = ~clk;

  // ==== the memory stub on the bus-master port ====
  // 256 bytes. THE ACCEPT AND THE COMPLETION ARE TWO DIFFERENT PULSES, and that is
  // the whole reason this stub was rewritten: mem_ready is the accept (one cycle
  // after the request) and mem_resp_valid is the completion (one cycle after
  // that), so a read's word IS NOT AVAILABLE in the accept cycle. The stub this
  // replaced drove a COMBINATIONAL mem_rdata that was already valid in the request
  // cycle, which made a same-cycle sample invisible; this one makes it observable.
  //
  // The byte is driven into ALL FOUR LANES. The controller replicates its write
  // byte for exactly this reason, so the stub does not have to agree with the
  // controller about lane order and reading mem_din[7:0] is correct either way.
  // The lane assertion below still holds, because a byte transfer that enabled two
  // lanes would be a different bug.
  //
  // The write commits at the ACCEPT, not at the request, which is what the real
  // backend does (src/memory/sdram.v accepts then returns; a write has no
  // response). A controller that drove valid data only after the accept would
  // still work here; one that expected the store to have happened at the request
  // would not, and the fidelity is worth the line.
  reg [7:0] mem [0:255];
  integer k;
  localparam integer LATENCY = 3;
  reg [31:0] mem_word = 0;
  reg [3:0]  pend = 0;
  always @(posedge clk) begin
    mem_ready      <= 1'b0;
    mem_resp_valid <= 1'b0;
    if (mem_req && !mem_ready && pend == 0) begin
      // THE ACCEPT. One cycle, and the store commits HERE -- a write has no
      // response, so a read arms a completion and a write does not.
      mem_ready <= 1'b1;
      if (!mem_we) begin
        mem_word <= {4{mem[mem_addr[7:0]]}};
        pend     <= LATENCY;
      end
    end else if (pend != 0) begin
      // THE COMPLETION, LATENCY cycles after the accept. mem_word is what the
      // backend PRODUCED and is not valid before this pulse -- which is the whole
      // property a combinational stub cannot express and the one the port rewrite
      // exists for.
      pend <= pend - 1;
      if (pend == 1) mem_resp_valid <= 1'b1;
    end
    if (mem_req && mem_we && mem_ready) mem[mem_addr[7:0]] <= mem_din[7:0];
  end
  always @(*) mem_dout = mem_word;

  // One lane at a time, or the stub above is lying about where the byte went.
  always @(posedge clk)
    if (mem_req && mem_we && (mem_be != 4'b0001) && (mem_be != 4'b0010) &&
        (mem_be != 4'b0100) && (mem_be != 4'b1000))
      $fatal(1, "the DMA drove byte lane %b, which is not one byte", mem_be);

  // ==== the device stub ====
  // The pull path (memory to port): count what the controller hands over and
  // remember the last byte, so S5 can check both the count and the data.
  reg [7:0] got_byte;
  integer   pull_count;
  always @(posedge clk)
    if (dev_stb && dev_we) begin
      got_byte   <= dev_dout;
      pull_count <= pull_count + 1;
    end

  // The push path (port to memory): the bus advances only when the controller
  // strobes it, which is what makes S4 a phase test.
  integer push_count;
  always @(posedge clk)
    if (dev_stb && !dev_we) begin
      dev_din    <= dev_din + 8'h01;
      push_count <= push_count + 1;
    end

  // ==== CHECKS ====
  // ==== register access helpers ====
  task automatic reg_wr(input [4:0] i, input [7:0] d);
    begin
      @(negedge clk); sel = 1'b1; write = 1'b1; idx = i; din = d;
      @(negedge clk); sel = 1'b0; write = 1'b0;
    end
  endtask

  reg [7:0] rd_val;
  task automatic reg_rd(input [4:0] i);
    begin
      @(negedge clk); sel = 1'b1; write = 1'b0; idx = i;
      @(negedge clk); rd_val = dout; sel = 1'b0;
    end
  endtask

  integer errors;
  task automatic expect8(input [7:0] want, input [255:0] what);
    begin
      if (rd_val !== want) begin
        $display("FAIL %0s: read %02x, the machine says %02x", what, rd_val, want);
        errors = errors + 1;
      end
    end
  endtask

  // Wait for a condition that a running engine should reach, or name the stall.
  integer spin;
  task automatic settle(input integer cycles);
    begin
      for (spin = 0; spin < cycles; spin = spin + 1) @(posedge clk);
    end
  endtask

  initial begin
    errors     = 0;
    pull_count = 0;
    push_count = 0;
    got_byte   = 8'h00;
    for (k = 0; k < 256; k = k + 1) mem[k] = 8'h00;

    repeat (4) @(posedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    // ---- S1: the low/high flip-flop, via the channel-0 address register ----
    // Two writes fill its low 16 bits and leave the flip-flop where they started,
    // which is the property the ITF's self-test below depends on.
    reg_wr(5'd0, 8'h34);
    reg_wr(5'd0, 8'h12);
    reg_rd(5'd0); expect8(8'h34, "ch0 address low byte");
    reg_rd(5'd0); expect8(8'h12, "ch0 address high byte");

    // ---- S2: the ITF's own self-test, transcribed ----
    // This is the exact shape of the test at BANK4@0xF83E8 in the machine's own
    // ITF, disassembled rather than assumed:
    //
    //   mov al,0xff / mov dx,0x1 / mov cx,8
    //   loop: mov bl,al / mov bh,bl
    //         out dx,al      <- write the value
    //         out dx,al      <- write it AGAIN
    //         in  al,dx      <- read it
    //         mov ah,al
    //         in  al,dx      <- read it AGAIN
    //         cmp bx,ax      <- BOTH reads must equal the written value
    //         add dx,2 / loop
    //   then the same pass with al = 0x00
    //
    // Two writes and two reads is not padding: it is what a chip with a low/high
    // byte flip-flop requires, because the flip-flop toggles on every access. The
    // two writes fill both bytes and the two reads return both, so the comparison
    // holds whatever state the pointer started in. A bench that wrote once and
    // read once -- which is what this case did before the firmware was read, and
    // it failed -- is testing a latch, not this chip.
    for (k = 0; k < 8; k = k + 1) begin
      // first pass: 0xFF
      reg_wr(k[4:0], 8'hFF);
      reg_wr(k[4:0], 8'hFF);
      reg_rd(k[4:0]); if (rd_val !== 8'hFF) begin
        $display("FAIL S2 idx %0d: first read %02x, the ITF requires FF", k, rd_val);
        errors = errors + 1;
      end
      reg_rd(k[4:0]); if (rd_val !== 8'hFF) begin
        $display("FAIL S2 idx %0d: second read %02x, the ITF requires FF", k, rd_val);
        errors = errors + 1;
      end
      // second pass: 0x00
      reg_wr(k[4:0], 8'h00);
      reg_wr(k[4:0], 8'h00);
      reg_rd(k[4:0]); if (rd_val !== 8'h00) begin
        $display("FAIL S2 idx %0d: first read %02x, the ITF requires 00", k, rd_val);
        errors = errors + 1;
      end
      reg_rd(k[4:0]); if (rd_val !== 8'h00) begin
        $display("FAIL S2 idx %0d: second read %02x, the ITF requires 00", k, rd_val);
        errors = errors + 1;
      end
    end

    // ---- S3: the machine's captured reads ----
    reg_rd(5'd8);  expect8(8'h00, "0x11 status at reset");
    reg_rd(5'd13); expect8(8'h00, "0x1B master clear reads 0x00 on the machine");
    reg_rd(5'd20); expect8(8'h00, "0x29 bound reads 0x00 on the machine");
    // 0x21..0x27, the BANK byte's PORT read: the CAPTURE'S LOW NIBBLE ALONE. RDBACK wrote
    // 0xA5 at 0x21 and read 0x05 back on every one of the four (docs/probes/RDBACK.TXT:153-156,
    // an "after" and a "back" read both 0x05, so the read is not a one-shot). The capture
    // outranks the software references here: NP2kai has NO read handler for these ports at all
    // (its dmaco21 table is sysout-only, io/dmac.c:354) and qemu returns the whole stored byte
    // (hw/dma/pc98-dma.c:296-298). The STORE stays the whole byte - NP2kai's compiled IA32
    // branch and qemu both keep it, and E7d above asserts that a bank of 0xFF reaches address
    // bits 23:16 - so it is the READ that masks. The IOBUS stub this state will move from
    // (the DMA engine) returns the same nibble, so the hand-off cannot move a guest byte.
    // FAIL-FIRST: before the mask both rows read the stored byte back (0xA5 / 0x3C).
    reg_wr(5'd16, 8'hA5);                 // 0x21 -> channel 1's bank (see the write arm)
    reg_rd(5'd16); expect8(8'h05, "0x21 bank with 0xA5 written reads the capture's low nibble");
    reg_rd(5'd16); expect8(8'h05, "...and the read does not consume it (RDBACK's after/back)");
    reg_rd(5'd17); expect8(8'h00, "0x23 is another channel's bank: untouched at 0x00");
    reg_wr(5'd17, 8'h3C);                 // 0x23 -> channel 2's bank
    reg_rd(5'd17); expect8(8'h0C, "0x23 bank masks to the low nibble too");
    // 0x29: `(dat >> 2) & 3` into the channel `dat & 3` selects, with CHANNEL 0 ALONE on the
    // read (NP2kai io/dmac.c:260-263 and qemu hw/dma/pc98-dma.c:269-272 store per channel,
    // which the capture cannot see - all three of its writes carry `dat & 3 == 0`).
    reg_wr(5'd20, 8'h0D);                 // channel 1, bound 3
    reg_rd(5'd20); expect8(8'h00, "0x29 exposes channel 0 alone: a channel-1 write leaves 0x00");
    reg_wr(5'd20, 8'h0C);                 // channel 0, bound 3 = the machine's row
    reg_rd(5'd20); expect8(8'h03, "0x29 channel-0 write 0C reads 03 (probes/RDBACK.TXT:157)");
    reg_rd(5'd9);  expect8(8'hFF, "0x13 software request is write-only");
    reg_rd(5'd10); expect8(8'hFF, "0x15 single mask is write-only");
    reg_rd(5'd11); expect8(8'hFF, "0x17 mode is write-only");
    reg_rd(5'd12); expect8(8'hFF, "0x19 clear flip-flop is write-only");
    reg_rd(5'd15); expect8(8'hFF, "0x1F all-mask is write-only");

    // ---- S4: port to memory, FOUR bytes from a count of 3 (the N+1 rule) ----
    dev_din = 8'hA0;
    reg_wr(5'd0, 8'h10);    // ch0 address = 0x0010
    reg_wr(5'd0, 8'h00);
    reg_wr(5'd1, 8'h03);    // ch0 count   = 0x0003 -> four bytes, not three
    reg_wr(5'd1, 8'h00);
    reg_wr(5'd11, 8'h04);   // ch0 mode: port to memory (bits 3:2 = 01), increment
    reg_wr(5'd10, 8'h00);   // unmask channel 0
    @(negedge clk);
    drq = 4'b0001;
    settle(60);
    drq = 4'b0000;
    settle(4);

    if (mem[8'h10] !== 8'hA0 || mem[8'h11] !== 8'hA1 ||
        mem[8'h12] !== 8'hA2 || mem[8'h13] !== 8'hA3) begin
      $display("FAIL S4: memory holds %02x %02x %02x %02x, expected A0 A1 A2 A3 (count 3 is FOUR bytes)",
               mem[8'h10], mem[8'h11], mem[8'h12], mem[8'h13]);
      errors = errors + 1;
    end
    if (mem[8'h14] !== 8'h00) begin
      $display("FAIL S4: a fifth byte was transferred, so the count is N and not N+1");
      errors = errors + 1;
    end
    if (push_count != 4) begin
      $display("FAIL S4: the device was strobed %0d times, expected 4", push_count);
      errors = errors + 1;
    end
    // The channel masks itself at terminal count, so it stopped on its own.
    reg_rd(5'd8); expect8(8'h01, "S4 terminal count for channel 0");
    // And reading the status cleared that bit.
    reg_rd(5'd8); expect8(8'h00, "S4 status clears its TC bits when read");

    // ---- S5: memory to port, TWO bytes from a count of 1 ----
    mem[8'h20] = 8'h5A;
    mem[8'h21] = 8'hC3;
    reg_wr(5'd2, 8'h20);    // ch1 address = 0x0020
    reg_wr(5'd2, 8'h00);
    reg_wr(5'd3, 8'h01);    // ch1 count   = 0x0001 -> two bytes
    reg_wr(5'd3, 8'h00);
    // The mode register carries its channel in data bits 1:0 (NP2kai dmac_o17:
    // `dmach[dat & 3].mode = dat`), NOT in the register index the way the address
    // and count registers do. So this is 0x08 | channel 1 = 0x09: transfer type
    // mem-to-port in bits 3:2, increment, and the channel in bits 1:0. Writing
    // 0x08 would set channel 0's mode instead and leave channel 1 with mode 0,
    // which is verify -- a transfer that strobes no memory and moves nothing.
    reg_wr(5'd11, 8'h09);
    // The single-mask register takes the channel in bits 1:0 and the sense in bit
    // 2, so unmasking CHANNEL 1 is a write of 0x01 -- 0x00 would unmask channel 0,
    // which is already masked from its own terminal count and would leave this
    // channel masked and the transfer silent.
    reg_wr(5'd10, 8'h01);
    pull_count = 0;
    @(negedge clk);
    drq = 4'b0010;
    settle(60);
    drq = 4'b0000;
    settle(4);

    if (pull_count != 2) begin
      $display("FAIL S5: the device received %0d bytes, expected 2", pull_count);
      errors = errors + 1;
    end
    if (got_byte !== 8'hC3) begin
      $display("FAIL S5: the device's last byte was %02x, expected C3", got_byte);
      errors = errors + 1;
    end

    // ---- S6: the address walked the right way, and only that channel moved ----
    // Channels 0 and 1 were programmed at 0x0010 and 0x0020; S4's four bytes and
    // S5's two were all the traffic there was, so nothing else in memory may have
    // been written.
    for (k = 0; k < 256; k = k + 1) begin
      if (k >= 8'h10 && k <= 8'h13) continue;
      if (mem[k] !== 8'h00 && !(k == 8'h20 || k == 8'h21)) begin
        $display("FAIL S6: memory %02x is %02x but only 0x10-0x13 should have been written",
                 k, mem[k]);
        errors = errors + 1;
      end
    end

    // ---- S7: the 0x11 status read clears ONLY the terminal-count nibble ----
    // NP2kai's dmac_i11 returns dmac.stat and then does `dmac.stat &= 0xf0`
    // (io/dmac.c:290-294): the read acknowledges the four terminal-count bits
    // and LEAVES the request-state nibble in bits 7:4 standing. Bits 7:4 are
    // seeded hierarchically because nothing in this module writes them yet (the
    // request state is named absent above); the read must not eat them anyway.
    // FAIL-FIRST: clearing 8'hFF on the read (the old stat_clr width) eats the
    // seeded nibble and the second read returns 00 instead of F0.
    repeat (2) @(negedge clk);
    dut.stat = 8'hF5;
    reg_rd(5'd8); expect8(8'hF5, "S7 0x11 returns all 8 stat bits");
    reg_rd(5'd8); expect8(8'hF0, "S7 0x11 clears only stat[3:0]");
    reg_rd(5'd8); expect8(8'hF0, "S7 stat[7:4] survives every read");

    // ==== VERDICT ====
    // ---- verdict ----
    if (errors != 0) $fatal(1, "%0d DMAC case(s) failed", errors);
    $display("DMAC register file and engine exercised in both directions");
    $display("TB_PC9821_DMAC: PASS");
    $finish;
  end

  // A bench that stops making progress names itself instead of hanging the runner.
  initial begin
    #8_000_000;
    $fatal(1, "the DMAC bench did not finish in 8 ms of simulated time");
  end

endmodule
