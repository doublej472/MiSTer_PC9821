// tb_pc9821_dmac_autoinit — the autoinitialize reload on every channel, byte lane by byte lane.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DMAC_AUTOINIT:
// The uPD71071's autoinitialize reload returns each channel to the values the guest PROGRAMMED, whatever the transfer has walked since: for each of the four channels a block is programmed with a distinct address (low byte, high byte and the 0x21-0x27 bank byte, whose port-to-channel map is NP2kai's ((port >> 1) + 1) & 3) and a count, the block is run through its terminal count and the next block starts again at exactly the programmed 24-bit address with the programmed length (checked on the bus addresses the engine presents, not on a register readback), a channel's reload is independent of the other three channels' programming, and re-programming only ONE byte lane of a channel afterwards (the address low byte, the count low byte, the bank byte) changes only that lane of its reload - the other lanes keep what was programmed before; and a count with a non-zero HIGH byte (0x0100, a 257-byte block) reloads whole, also after its low lane alone is re-programmed (0x0102, 259 bytes).

// ==== DUT ====
module tb_pc9821_dmac_autoinit;

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
  wire [31:0] mem_addr;
  wire        mem_we;
  wire [3:0]  mem_be;
  wire [31:0] mem_din;
  wire        mem_req;
  wire        mem_ready = mem_req;          // the backend accepts at once
  reg         mem_resp_valid = 0;
  wire [31:0] mem_dout = 32'h5A5A5A5A;
  wire        mem_tc;

  pc9821_dmac dut (
    .clk(clk), .reset(reset),
    .sel(sel), .write(write), .idx(idx), .din(din), .dout(dout), .dout_comb(),
    .dev_drq(drq), .dev_dack(dack), .dev_we(dev_we), .dev_stb(dev_stb),
    .dev_tc(dev_tc), .dev_ch(dev_ch), .dev_dout(dev_dout), .dev_din(8'h00),
    .mem_addr(mem_addr), .mem_we(mem_we), .mem_be(mem_be), .mem_din(mem_din),
    .mem_dout(mem_dout), .mem_req(mem_req),
    .mem_ready(mem_ready), .mem_resp_valid(mem_resp_valid), .mem_tc(mem_tc)
  );

  always #5 clk = ~clk;
  always @(posedge clk) mem_resp_valid <= mem_req && !mem_we;

  // every address the engine presented, in order
  reg [23:0] log [0:1023];
  integer    log_n = 0;
  always @(posedge clk) if (mem_req && mem_ready) begin
    if (log_n < 1024) log[log_n[9:0]] <= mem_addr[23:0];   // the first 1024 only: a level request never stops
    log_n <= log_n + 1;
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

  // the bank port of channel c: NP2kai's channel is ((port >> 1) + 1) & 3, so idx[1:0] = c - 1
  function automatic [4:0] bank_idx(input [1:0] c);
    bank_idx = 5'd16 + {3'd0, c - 2'd1};
  endfunction

  // Program channel c: autoinitialize read (memory to device), address a, bank b, count n.
  task automatic prog(input [1:0] c, input [15:0] a, input [7:0] b, input [15:0] n);
    begin
      reg_wr(5'd13, 8'h00);              // master clear
      reg_wr(5'd12, 8'h00);              // clear the byte flip-flop
      reg_wr(5'd11, {6'b000110, c});     // mode: read (bits 3:2 = 10) with autoinitialize (bit 4)
      reg_wr({2'b00, c, 1'b0}, a[7:0]);  // address low, then high
      reg_wr({2'b00, c, 1'b0}, a[15:8]);
      reg_wr(bank_idx(c), b);
      reg_wr({2'b00, c, 1'b1}, n[7:0]);  // count low, then high
      reg_wr({2'b00, c, 1'b1}, n[15:8]);
    end
  endtask

  // Run channel c for a fixed span and leave the request low.
  task automatic run(input [1:0] c, input integer cycles);
    begin
      log_n = 0;
      reg_wr(5'd14, 8'h00);              // clear all masks
      drq[c] = 1'b1;
      repeat (cycles) @(negedge clk);
      drq[c] = 1'b0;
      repeat (12) @(negedge clk);
      reg_wr(5'd15, 8'h0F);              // mask everything again
    end
  endtask

  // Blocks of `len` bytes starting at `base`: the log reads base, base+1, .., base+len-1, base, ...
  task automatic expect_blocks(input [1:0] c, input [23:0] base, input integer len, input [255:0] what);
    integer j;
    begin
      check(log_n >= 2 * len, what);
      for (j = 0; j < 2 * len && j < log_n; j = j + 1)
        if (log[j] !== base + (j % len)) begin
          $display("  %0s: channel %0d request %0d at %06x, want %06x", what, c, j, log[j], base + (j % len));
          fails = fails + 1;
          j = 2 * len;
        end
    end
  endtask

  integer c, j0, first_reload;
  initial begin
    repeat (8) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);

    // ---- every channel: the programmed address, bank and count come back after the terminal count ----
    for (c = 0; c < 4; c = c + 1) begin
      prog(c[1:0], 16'h1200 + 16'h0101 * c, 8'h30 + c, 16'h0002);   // 3 bytes per block
      run(c[1:0], 400);
      expect_blocks(c[1:0], {8'h30 + c[7:0], 16'h1200 + 16'h0101 * c[15:0]}, 3,
                    "the reload did not return to the programmed address and length");
    end

    // ---- one lane at a time: channel 2 (a channel whose lanes differ from 0's) ----
    prog(2'd2, 16'h4321, 8'h5C, 16'h0003);                          // 4 bytes per block
    run(2'd2, 500);
    expect_blocks(2'd2, 24'h5C4321, 4, "channel 2 baseline");

    // the address LOW byte alone (flip-flop cleared, so it lands in the low half)
    reg_wr(5'd12, 8'h00);
    reg_wr(5'd4, 8'h77);
    run(2'd2, 500);
    expect_blocks(2'd2, 24'h5C4377, 4, "re-programming the address low byte moved another lane");

    // the bank byte alone
    reg_wr(bank_idx(2'd2), 8'hA9);
    run(2'd2, 500);
    expect_blocks(2'd2, 24'hA94377, 4, "re-programming the bank byte moved another lane");

    // the count LOW byte alone
    reg_wr(5'd12, 8'h00);
    reg_wr(5'd5, 8'h01);                                            // count 3 -> 1: two bytes
    run(2'd2, 500);
    expect_blocks(2'd2, 24'hA94377, 2, "re-programming the count low byte moved another lane");

    // ---- a count with a HIGH byte: channel 1, count 0x0100 = 257 bytes per block ----
    // The 8237 family reloads the whole 16-bit base count at terminal count; a block longer than
    // 256 bytes (a sound ring buffer) depends on the high lane coming back too.
    prog(2'd1, 16'h2000, 8'h41, 16'h0100);
    run(2'd1, 12000);
    expect_blocks(2'd1, 24'h412000, 257, "a count with a non-zero high byte did not reload whole");

    // the count LOW byte alone, with the high byte non-zero: 0x0100 -> 0x0102, 259 bytes. The
    // channel was stopped mid-block, so its current address and count are mid-block too: the
    // blocks are judged from the first reload on (the first return to the base address).
    reg_wr(5'd12, 8'h00);
    reg_wr(5'd3, 8'h02);
    run(2'd1, 40000);
    first_reload = -1;
    for (j0 = 1; j0 < log_n && j0 < 1024 && first_reload < 0; j0 = j0 + 1)
      if (log[j0] === 24'h412000 && log[j0 - 1] !== 24'h411FFF) first_reload = j0;
    check(first_reload >= 0 && first_reload + 2 * 259 <= log_n && first_reload + 2 * 259 <= 1024,
          "the channel did not reload and run two blocks after its count low byte was re-programmed");
    if (first_reload >= 0)
      for (j0 = 0; j0 < 2 * 259 && first_reload + j0 < 1024; j0 = j0 + 1)
        if (log[first_reload + j0] !== 24'h412000 + 24'(j0 % 259)) begin
          $display("  re-programming the count low byte lost the count high byte: request %0d after the reload at %06x, want %06x",
                   j0, log[first_reload + j0], 24'h412000 + 24'(j0 % 259));
          fails = fails + 1;
          j0 = 2 * 259;
        end

    // ==== VERDICT ====
    if (fails == 0) begin
      $display("TB_PC9821_DMAC_AUTOINIT: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_DMAC_AUTOINIT: FAIL (%0d errors)", fails);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_DMAC_AUTOINIT: TIMEOUT");
  end
endmodule
