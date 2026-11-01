// ==== WHAT THIS PROVES ====
// The uPD71071's transfer engine against a backend with the shape the memory subsystem actually presents - an accept pulse and a SEPARATE completion pulse several cycles later, the returned word valid only at the completion, and the backend's produced-word register starting at a sentinel so a read taken a cycle early returns a value this bench can name. A read that sampled its byte at the accept instead of the completion fails here and passes the module's earlier engine bench, because that bench's memory stub drove a COMBINATIONAL read data path that was already valid in the request cycle. Plus both directions of transfer, the N+1 count at its boundary, the decrement bit, terminal count with the mask and the autoinitialize reload, and a write finishing at the accept with no completion pulse at all. The E7/D2 cases pin the FDC-DMA fixes: terminal count must coincide with the final dack/strobe (8237 EOP-during-final-transfer qualification; FAIL-FIRST against the old late registered pulse), and a CPU register write landing in the engine's S_FIN cycle must LAND - its byte lane of the count/address wins over the engine advance or reload (merged readback), the fresh terminal count survives the count write's own TC clear (set-wins), and R_CLEARMSK beats the TC mask so a held DRQ runs the block again (FAIL-FIRST against the old source-order resolution). E7d pins the fold's bank path: a 0x21-0x27 bank write landing in the S_FIN whose increment carries out of bit 23 must zero adrs.b[31:24] as NP2kai's dmac_o21 does on every bank write (io/dmac.c:242), so the next block runs in the low 16 MiB (FAIL-FIRST against the fold keeping the carried upper bits).
//
// The uPD71071's transfer engine against a backend with the shape the memory subsystem actually presents - an accept pulse and a SEPARATE completion pulse several cycles later, the returned word valid only at the completion, and the backend's produced-word register starting at a sentinel so a read taken a cycle early returns a value this bench can name. A read that sampled its byte at the accept instead of the completion fails here and passes the module's earlier engine bench, because that bench's memory stub drove a COMBINATIONAL read data path that was already valid in the request cycle. Plus both directions of transfer, the N+1 count at its boundary, the decrement bit, terminal count with the mask and the autoinitialize reload, and a write finishing at the accept with no completion pulse at all.
//
// WHY THIS BENCH EXISTS AND THE OTHER ONE DOES NOT REPLACE IT. tb_pc9821_dmac
// covers the register file and the transfer phases, and it passes. Its memory stub
// is `always @(*) mem_rdata = mem[mem_addr]` with a one-cycle acknowledge, so the
// byte was correct in EVERY cycle of a read and the timing question could not be
// asked. A bench cannot test a latency contract its model does not have, and that
// is the same blindness that let the route-isolation defect survive a green suite
// for a week. Here the produced word is a REGISTER that only changes at the accept,
// it starts at a sentinel rather than at the memory contents, and the completion is
// a distinct pulse LATENCY cycles after the accept.
//
// FALSIFIABILITY, and this bench was built around it. The property under test is
// "the read byte is sampled at the completion, not at the accept". It is shown to
// CAN FAIL by reverting the module to the single-ack behaviour it carried before
// this bench: sampling at the accept returns the sentinel (0xA5) instead of the
// memory's byte on the first transfer and the previous word's byte thereafter.
// That plant was run and observed failing on E1 before the good RTL was restored.
// Two further plants were observed: masking the request with the status nibble
// instead of the mask register makes E1 transfer nothing, and dropping the count
// decrement makes E3 move the wrong number of bytes.
//
// WHAT THIS DOES NOT SETTLE. Whether the machine transfers N or N+1 bytes for a
// programmed count: the ITF's self-test never starts a transfer, so IT cannot tell.
// The boundary IS settled against the primary software reference, though - NP2kai's
// transfer engine (the code that runs) tests leng BEFORE decrementing
// (mem/dmax86.c:19-24), so its byte consuming a zero count still moves and it is N+1
// too; only the bulk helper dmac_getdatas is N (not "NP2kai uses N", which misreads
// dmax86.c). E3 pins the boundary THIS module implements so a change to
// it cannot pass silently.

// ==== DUT ====
module tb_pc9821_dmac_engine;

  reg        clk = 0;
  reg        reset = 1;
  reg        sel = 0, write = 0;
  reg  [4:0] idx = 0;
  reg  [7:0] din = 0;
  wire [7:0] dout;

  reg  [3:0] drq = 0;
  wire [3:0] dack;
  wire       dev_we, dev_stb, dev_tc;
  wire [1:0] dev_ch;
  wire [7:0] dev_dout;
  wire [7:0] dev_din;

  wire [31:0] mem_addr;
  wire        mem_we;
  wire [3:0]  mem_be;
  wire [31:0] mem_din;
  wire        mem_req;
  wire        mem_ready;
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

  // ==== the backend, with the real shape ====
  // An accept, then a completion LATENCY cycles later. The produced word is a
  // REGISTER initialised to SENTINEL, so a read sampled before the completion
  // returns 0xA5 rather than the byte -- which is the whole discriminator. A write
  // arms no completion at all, because the backend returns nothing for a write.
  localparam integer LATENCY = 4;
  localparam [31:0]  SENTINEL = 32'hA5A5A5A5;
  reg [7:0]  mem [0:255];
  reg [31:0] produced = SENTINEL;
  reg [3:0]  pend = 0;
  integer    acc_count = 0;
  integer    rsp_count = 0;
  integer    sentinel_seen = 0;
  // The full 32-bit address of every accepted request: E7d pins WHERE the merged
  // bank-write/S_FIN collision runs the next block (0x000A0000 vs the stale
  // 0x010A0000), and the 256-byte array aliases those two to the same byte.
  reg [31:0] req_addr [0:3];
  integer    req_n = 0;

  // THE ACCEPT IS IMMEDIATE, and that detail is the whole discriminator. The
  // subsystem says mem_ready "may be permanently high", so it is a LEVEL that
  // answers a request in the cycle the request is present -- not a pulse a cycle
  // later. The word then appears LATENCY cycles after that.
  //
  // An earlier draft of this model REGISTERED the accept, which put the accept in
  // the same cycle as the load of `produced`, so a controller sampling its byte at
  // the accept saw the correct word anyway and the plant did not fail. That is the
  // same shape as the blindness this bench was written to remove: a model that
  // cannot express the timing cannot test it. Found by the plant NOT failing.
  wire acc_now = mem_req && (pend == 0);
  always @(posedge clk) begin
    mem_resp_valid <= 1'b0;
    if (acc_now) begin
      if (!mem_we) begin
        // A read: the word is loaded AT the accept and is not visible until the
        // completion, so a sample taken in the accept cycle sees the PREVIOUS
        // value -- the sentinel on the first transfer. The backend ignores
        // addr[1:0] (src/memory/sdram.v:95 `addr0, // byte address (bits [1:0] ignored)`)
        // and returns the ALIGNED 32-bit word, so each byte sits in its own lane
        // (`mem[{p,2'bxx}]`) and mem_rd_byte's lane choice is observable here. An
        // earlier model replicated the byte into all four lanes, which hid a
        // mem_rd_byte lane-order defect; that is the blindness this now removes.
        produced <= {mem[{mem_addr[7:2], 2'b11}], mem[{mem_addr[7:2], 2'b10}],
                     mem[{mem_addr[7:2], 2'b01}], mem[{mem_addr[7:2], 2'b00}]};
        pend     <= LATENCY;
      end else begin
        // A write commits AT the accept and arms no completion at all.
        mem[mem_addr[7:0]] <= mem_din[7:0];
      end
    end else if (pend != 0) begin
      pend <= pend - 1;
      if (pend == 1) mem_resp_valid <= 1'b1;   // THE COMPLETION, LATENCY cycles later
    end
    if (acc_now) acc_count <= acc_count + 1;
    if (mem_resp_valid) rsp_count <= rsp_count + 1;
    if (acc_now) begin
      req_addr[req_n[1:0]] <= mem_addr;
      req_n                <= req_n + 1;
    end
  end
  // The accept as the backend presents it: a level, not a registered pulse.
  assign mem_ready = acc_now;
  always @(*) mem_dout = produced;

  // A byte transfer drives exactly one lane, and the lane must be the address's
  // low bits -- sdram.v ignores addr[1:0] and takes the byte from mem_be, so a
  // disagreement between them puts the byte in the wrong place silently.
  always @(posedge clk)
    if (mem_req) begin
      if ((mem_be != 4'b0001) && (mem_be != 4'b0010) &&
          (mem_be != 4'b0100) && (mem_be != 4'b1000))
        $fatal(1, "the DMA drove byte lane %b, which is not one byte", mem_be);
      if (mem_be != (4'b0001 << mem_addr[1:0]))
        $fatal(1, "the DMA drove byte lane %b for address low bits %b, which disagree",
               mem_be, mem_addr[1:0]);
      // Replicated into every lane, so the backend's lane order cannot matter.
      if ((mem_din[7:0] != mem_din[15:8]) || (mem_din[15:8] != mem_din[23:16]) ||
          (mem_din[23:16] != mem_din[31:24]))
        $fatal(1, "the DMA's write byte is not replicated across lanes: %08x", mem_din);
    end

  // ==== the device stub ====
  reg [7:0] pushed [0:15];   // bytes the controller handed the device
  integer   push_n = 0;
  integer   tc_n = 0;

  // The bytes the device PRESENTS, advanced by one on every strobe that takes a
  // byte away. A real device puts the next byte on the bus after each DACK; an
  // earlier draft of this bench changed dev_din on a timer instead, so the whole
  // block read the SAME byte four times and E2 failed for the bench's reason
  // rather than the engine's. The unit under test decides when a byte moves.
  reg [7:0] out_seq [0:15];
  integer   out_n = 0;
  assign dev_din = out_seq[out_n];

  // D2's qualification pin: every dev_tc must coincide with the
  // channel's dev_dack AND the strobe - the 8237 asserts EOP during the final transfer
  // cycle and NP2kai fires DMAEXT_END in the final byte's own engine step, so a device
  // may qualify EOP with its DACK. The old registered tc_pulse arrived >= 2 cycles after
  // the final strobe with every dack down, and counts as tc_late here.
  integer tc_late = 0;

  always @(posedge clk) begin
    if (dev_stb && dev_we) begin
      pushed[push_n] <= dev_dout;
      push_n <= push_n + 1;
      if (dev_dout === SENTINEL[7:0]) sentinel_seen <= sentinel_seen + 1;
    end
    // A strobe that takes a byte from the device advances the device's pointer.
    if (dev_stb && !dev_we && out_n < 15) out_n <= out_n + 1;
    if (dev_tc) begin
      tc_n <= tc_n + 1;
      if (!(dev_stb && dack[dev_ch])) tc_late <= tc_late + 1;
    end
  end

  // ==== CHECKS ====
  integer fails = 0;
  task automatic check(input ok, input [1023:0] what);
    begin
      if (!ok) begin
        fails = fails + 1;
        $display("FAIL: %0s", what);
      end
    end
  endtask

  task automatic reg_wr(input [4:0] i, input [7:0] d);
    begin
      @(negedge clk); sel <= 1; write <= 1; idx <= i; din <= d;
      @(negedge clk); sel <= 0; write <= 0;
    end
  endtask

  // A register write presented in the EXACT S_FIN cycle:
  // the setup lands on the negedge inside S_FIN, so the write and the engine's advance/
  // reload commit on the same posedge. reg_wr's own @(negedge) entry would sample S_FIN
  // one cycle late, so this form synchronises on dut.state instead.
  task automatic reg_wr_at_fin(input [4:0] i, input [7:0] d);
    begin
      while (dut.state != 3'd4) @(negedge clk);   // S_FIN == 3'd4
      sel <= 1; write <= 1; idx <= i; din <= d;
      @(negedge clk); sel <= 0; write <= 0;
    end
  endtask

  reg [7:0] rd_val;
  task automatic reg_rd(input [4:0] i);
    begin
      @(negedge clk); sel <= 1; write <= 0; idx <= i;
      @(negedge clk); rd_val = dout; sel <= 0;
    end
  endtask

  task automatic settle(input integer cycles);
    begin repeat (cycles) @(negedge clk); end
  endtask

  // Program channel 0's address and count through the real flip-flop: each write
  // to the same index alternates low then high.
  task automatic prog_ch0(input [15:0] a, input [15:0] c, input [7:0] m);
    begin
      reg_wr(5'd13, 8'h00);          // master clear: mask all, zero the registers
      reg_wr(5'd12, 8'h00);          // clear the byte flip-flop: 0x1B no longer does
                                     // (NP2kai's dmac_o1b leaves dmac.lh alone - D4)
      reg_wr(5'd11, m);              // mode
      reg_wr(5'd0,  a[7:0]);         // address low
      reg_wr(5'd0,  a[15:8]);        // address high
      reg_wr(5'd1,  c[7:0]);         // count low
      reg_wr(5'd1,  c[15:8]);        // count high
      reg_wr(5'd14, 8'h00);          // clear all masks
    end
  endtask

  integer i;

  initial begin
    reset = 1;
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);

    // ---- E1: memory to device, through a backend with a LATENCY ----
    // Four bytes at 0x0000 with a programmed count of 3, which is four transfers
    // under the N+1 convention. The bytes are chosen so none equals the sentinel's
    // low byte, so a read taken at the accept cannot be mistaken for a correct one.
    for (i = 0; i < 256; i = i + 1) mem[i] = 8'h00;
    mem[0] = 8'h11; mem[1] = 8'h22; mem[2] = 8'h33; mem[3] = 8'h44;
    mem[4] = 8'h55; mem[5] = 8'h66; mem[6] = 8'h77; mem[7] = 8'h88;
    prog_ch0(16'h0000, 16'h0003, 8'h08);   // type 10 = read = memory to device
    push_n = 0; tc_n = 0; sentinel_seen = 0; acc_count = 0; rsp_count = 0;
    drq[0] = 1;
    settle(120);
    drq[0] = 0;
    check(push_n == 4, "E1: a programmed count of 3 did not move 4 bytes");
    check(pushed[0] === 8'h11, "E1: the first byte the device got is not mem[0]");
    check(pushed[1] === 8'h22, "E1: the second byte is not mem[1]");
    check(pushed[2] === 8'h33, "E1: the third byte is not mem[2]");
    check(pushed[3] === 8'h44, "E1: the fourth byte is not mem[3]");
    check(sentinel_seen == 0,
          "E1: the device was handed the backend's sentinel -- the read was sampled before the completion");
    check(rsp_count >= 4, "E1: the backend never completed a read");
    check(tc_n == 1, "E1: terminal count was not reported exactly once");
    check(acc_count == 4, "E1: the backend accepted a number of requests other than 4");

    // ---- E2: device to memory, and a write arms no completion ----
    for (i = 0; i < 256; i = i + 1) mem[i] = 8'h00;
    prog_ch0(16'h0010, 16'h0003, 8'h04);   // type 01 = write = device to memory
    push_n = 0; tc_n = 0; rsp_count = 0; out_n = 0;
    out_seq[0] = 8'hC1; out_seq[1] = 8'hC2; out_seq[2] = 8'hC3; out_seq[3] = 8'hC4;
    drq[0] = 1;
    settle(160);
    drq[0] = 0;
    check(mem[16] == 8'hC1, "E2: the first byte did not reach memory at 0x10");
    check(mem[17] == 8'hC2, "E2: the second byte did not reach memory at 0x11");
    check(mem[18] == 8'hC3, "E2: the third byte did not reach memory at 0x12");
    check(mem[19] == 8'hC4, "E2: the fourth byte did not reach memory at 0x13");
    check(rsp_count == 0,
          "E2: the backend completed a response for a write -- a write must finish at the accept");

    // ---- E3: the N+1 boundary, a count of zero is one byte ----
    for (i = 0; i < 256; i = i + 1) mem[i] = 8'h00;
    mem[0] = 8'h7E;
    prog_ch0(16'h0000, 16'h0000, 8'h08);
    push_n = 0; tc_n = 0;
    drq[0] = 1; settle(120); drq[0] = 0;
    check(push_n == 1, "E3: a programmed count of 0 did not move exactly one byte (N+1)");
    check(tc_n == 1, "E3: a one-byte block did not report terminal count once");

    // ---- E4: the decrement bit walks the address down ----
    mem[3] = 8'hA1; mem[4] = 8'hA2;
    prog_ch0(16'h0004, 16'h0001, 8'h28);   // type 10, bit 5 set = decrement
    push_n = 0;
    drq[0] = 1; settle(120); drq[0] = 0;
    check(push_n == 2, "E4: a decrementing block did not move two bytes");
    check(pushed[0] === 8'hA2, "E4: the first byte of a decrementing block is not mem[4]");
    check(pushed[1] === 8'hA1, "E4: the second byte of a decrementing block is not mem[3]");

    // ---- E5: the channel is masked at terminal count ----
    reg_rd(5'd8);                          // reading 0x11 returns the status
    check(rd_val[0] == 1'b1, "E5: channel 0's terminal count is not in the status");
    reg_rd(5'd1);                          // the count register, low half
    check(rd_val == 8'hFF, "E5: the counter does not wrap to 0xFFFF after a block");
    reg_wr(5'd15, 8'h01);                  // write all masks: channel 0 masked
    push_n = 0;
    drq[0] = 1; settle(80); drq[0] = 0;
    check(push_n == 0, "E5: the engine transferred with the channel masked");

    // ---- E6: autoinitialize reloads the address and count, and does NOT mask ----
    // An autoinitializing channel with a LEVEL request runs block after block --
    // that is what autoinitialize is for, and it is how a sound card drains a ring
    // buffer without a driver re-arming each block. So the assertion is that it
    // transfers WHOLE blocks, that the byte pattern REPEATS (which it can only do
    // if the address reloaded), and that a second block ran at all (which it can
    // only do if terminal count did NOT mask the channel). An earlier draft of this
    // case expected exactly two bytes and failed with twelve; the engine was right
    // and the expectation was, and the three checks below say what the hardware
    // does rather than what a single-shot block would do.
    mem[0] = 8'hE1; mem[1] = 8'hE2;
    prog_ch0(16'h0000, 16'h0001, 8'h18);   // type 10, bit 4 set = autoinitialize
    push_n = 0;
    drq[0] = 1; settle(120); drq[0] = 0;
    check(push_n >= 2 && (push_n % 2) == 0,
          "E6: an autoinitializing channel did not transfer whole two-byte blocks");
    check(pushed[0] === 8'hE1, "E6: the first byte of the block is not mem[0]");
    check(pushed[1] === 8'hE2, "E6: the second byte of the block is not mem[1]");
    check(push_n >= 4,
          "E6: only one block ran, so terminal count masked the channel and autoinitialize did not survive it");
    check(pushed[2] === 8'hE1,
          "E6: the second block did not restart at mem[0] -- the address did not reload");

    // The registers themselves, read back. Autoinitialize restores BOTH halves, so
    // the walked address and the decremented count are gone -- the address walked to
    // 0x0002 during the blocks, so reading 0x0000 is a reload and not just the start.
    //
    // AND THE FLIP-FLOP IS GLOBAL, which this case asserts rather than works around:
    // each read advances it, so the SECOND read of a register returns its HIGH half
    // and a read of the COUNT moves which half the ADDRESS read lands in. Getting
    // that wrong is how this case failed twice while being written; the sequence
    // below pins it, and it is a stronger statement than the authentic self-test
    // makes, because that test compares both halves against the SAME written byte
    // and so cannot see the pointer move at all.
    reg_rd(5'd1);
    check(rd_val == 8'h01, "E6: autoinitialize did not reload the count low half");
    reg_rd(5'd1);
    check(rd_val == 8'h00, "E6: the count high half is not zero, or the flip-flop did not advance");
    reg_rd(5'd0);
    check(rd_val == 8'h00, "E6: autoinitialize did not reload the address, or the pointer is not shared across registers");
    reg_rd(5'd0);
    check(rd_val == 8'h00, "E6: the address high half is not zero");
    reg_rd(5'd8);
    check(rd_val[0] == 1'b1, "E6: the autoinitialize block did not report terminal count");

    // ---- D2: every terminal count coincided with its DACK/strobe ----
    check(tc_late == 0,
          "D2: dev_tc fired outside the final dack/strobe cycle (EOP and DACK are not coherent)");

    // ---- E7: a CPU register write landing in the S_FIN cycle is NOT dropped -------
    // The register arms and the engine step write the same state;
    // the CPU write used to lose to S_FIN's later NBA silently (and leave the _org copy
    // holding a value the live register never saw). On the chip, and in NP2kai, the CPU
    // access always lands. FAIL-FIRST: every bound below fails against the old
    // source-order resolution.
    //
    // E7a: a count-half write at the terminal S_FIN. The engine wraps the counter to
    // 0xFFFF at TC; the CPU's low byte must win its lane (merged readback 0xFF33), and
    // the fresh terminal count must SURVIVE the count write's own TC clear (the stat
    // fold is set-wins: that clear acknowledges the OLD TC, this TC is a new event).
    for (i = 0; i < 256; i = i + 1) mem[i] = 8'h00;
    mem[0] = 8'h5C;
    prog_ch0(16'h0000, 16'h0000, 8'h08);   // one byte (count 0 = N+1 = 1)
    reg_wr(5'd12, 8'h00);                  // flip-flop low: the write below is a LOW write
    push_n = 0;
    drq[0] = 1;
    reg_wr_at_fin(5'd1, 8'h33);            // count low half, in the TC's S_FIN cycle
    settle(30);
    drq[0] = 0;
    settle(10);
    check(push_n == 1, "E7a: the one-byte block did not move exactly one byte");
    reg_rd(5'd8);
    check(rd_val[0] == 1'b1,
          "E7a: the fresh terminal count lost to the count write's TC clear (set must win)");
    reg_wr(5'd12, 8'h00);                  // read the halves low-then-high
    reg_rd(5'd1);
    check(rd_val == 8'h33, "E7a: the count write in the S_FIN cycle was dropped (low half)");
    reg_rd(5'd1);
    check(rd_val == 8'hFF, "E7a: the count wrap at TC lost its high half");

    // E7b: an address-half write at the terminal S_FIN. The engine advances the
    // address to 0x0001; the CPU's low byte must win its lane (merged 0x005A).
    prog_ch0(16'h0000, 16'h0000, 8'h08);
    reg_wr(5'd12, 8'h00);
    push_n = 0;
    drq[0] = 1;
    reg_wr_at_fin(5'd0, 8'h5A);            // address low half, in the TC's S_FIN cycle
    settle(30);
    drq[0] = 0;
    settle(10);
    check(push_n == 1, "E7b: the one-byte block did not move exactly one byte");
    reg_wr(5'd12, 8'h00);
    reg_rd(5'd0);
    check(rd_val == 8'h5A, "E7b: the address write in the S_FIN cycle was dropped (low half)");
    reg_rd(5'd0);
    check(rd_val == 8'h00, "E7b: the S_FIN advance bled into the CPU-written lane");

    // E7c: R_CLEARMSK (0x1D) at the terminal S_FIN. The engine masks the channel at
    // TC; the CPU's explicit clear-masks write is a direct order and must win its bits,
    // so a still-held drq runs the channel AGAIN (the counter wrapped to 0xFFFF).
    // FAIL-FIRST: with the engine's mask winning, the block stops after one byte.
    mem[0] = 8'h31; mem[1] = 8'h32;
    prog_ch0(16'h0000, 16'h0000, 8'h08);
    push_n = 0;
    drq[0] = 1;
    reg_wr_at_fin(5'd14, 8'h00);           // clear masks, in the TC's S_FIN cycle
    settle(30);
    drq[0] = 0;
    settle(10);
    check(push_n >= 2,
          "E7c: R_CLEARMSK in the S_FIN cycle was dropped (the TC mask ate the CPU's unmask)");

    // E7d: a BANK byte write at the terminal S_FIN -- the fold's bank path.
    // NP2kai's dmac_o21 zeroes adrs.b[DMA32_HIGH + DMA16_HIGH] on EVERY bank
    // write (`dmach->adrs.b[...] = 0`, io/dmac.c:242), and the block below runs
    // at 0xFFFFFF so the engine's own `ch->adrs.d += 1` (mem/dmax86.c:38)
    // carries OUT of bit 23 in the very S_FIN the write collides with. The
    // merged result must be {7'b0, 0x0A, the incremented low 16} = 0x000A0000.
    // FAIL-FIRST: keeping addr_base[30:24] in the fold leaves the carried 0x01
    // standing and the next block runs at 0x010A0000 (same byte in this 256-byte
    // stub, hence the request-address log).
    prog_ch0(16'hFFFF, 16'h0000, 8'h08);   // one byte at 0xFFFFFF (with bank FF below)
    reg_wr(5'd19, 8'hFF);                  // ch0's bank byte (0x27 -> ((0x27>>1)+1)&3 = ch0)
    push_n = 0; req_n = 0;
    drq[0] = 1;
    reg_wr_at_fin(5'd19, 8'h0A);           // bank write, in the TC's S_FIN cycle
    settle(30);
    drq[0] = 0;
    settle(10);
    check(push_n == 1, "E7d: the one-byte block did not move exactly one byte");
    check(req_addr[0] === 32'h00FFFFFF, "E7d: the setup byte did not run at 0xFFFFFF");
    reg_wr(5'd1, 8'h00); reg_wr(5'd1, 8'h00); // count 0 again (TC wrapped it to 0xFFFF)
    reg_wr(5'd14, 8'h00);                  // the TC masked the channel
    req_n = 0;
    drq[0] = 1;
    settle(60);
    drq[0] = 0;
    settle(10);
    check(req_n >= 1, "E7d: the second block never touched memory");
    check(req_addr[0] === 32'h000A0000,
          "E7d: the bank write in the S_FIN cycle kept the carried upper bits (NP2kai dmac_o21 zeroes adrs.b[31:24], io/dmac.c:242)");

  // ==== VERDICT ====
    if (fails == 0) begin
      $display("DMAC engine: transfers complete against a backend whose accept and completion are different pulses");
      $display("TB_PC9821_DMAC_ENGINE: PASS");
      $finish;
    end else begin
      $fatal(1, "the DMAC engine bench failed %0d check(s)", fails);
    end
  end

  // A bench that stops making progress names itself instead of hanging the runner.
  initial begin
    #8_000_000;
    $fatal(1, "the DMAC engine bench did not finish in 8 ms of simulated time");
  end

endmodule
