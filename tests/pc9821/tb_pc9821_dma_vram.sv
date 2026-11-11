`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The uPD71071 DMA engine's memory-side behaviour against NP2kai's reference: a byte transfer reads and writes the right byte, lane and address in both directions on every channel, a programmed count of N moves N+1 bytes, the 0x21-0x27 bank byte reaches address bits 23:16 (so a VRAM target at 0xA8000 and a banked target at 0x0B0000 both land where programmed while the low 64 KiB is untouched), autoinitialize reloads the address and count, and decrement walks down. B1 pins what a bank write ZEROES: address bits 30:24 go to zero on every 0x21-0x27 write (NP2kai dmac_o21, io/dmac.c:242), so a bank reprogram after an increment carried out of bit 23 returns the channel to the low 16 MiB (FAIL-FIRST against the stale upper bits running the block at 0x01xxxxxx). Plus the cases the reference disagrees on or the RTL does not model, each named with its reference: the 0x29 address-mode field that MAME's PC-9801 uses to decide whether the counter carries across a 64 KiB page is latched and never applied, so a block crossing 0xFFFF carries into the bank byte where MAME's default wraps within the page; single-transfer mode moves the whole block for a held DRQ where the 8237 moves one byte per request; and there is no memory-to-memory mode, so a VRAM-to-VRAM blit cannot be programmed.
//
// The uPD71071 DMA engine's memory-side behaviour against NP2kai's reference: a byte transfer reads and writes the right byte, lane and address in both directions on every channel, a programmed count of N moves N+1 bytes, the 0x21-0x27 bank byte reaches address bits 23:16 (so a VRAM target at 0xA8000 and a banked target at 0x0B0000 both land where programmed while the low 64 KiB is untouched), autoinitialize reloads the address and count, and decrement walks down. Plus B1's stale-upper-bit pin: a bank write zeroes address bits 30:24 as NP2kai's dmac_o21 does (io/dmac.c:242), so a bank reprogram after an increment carried out of bit 23 returns the channel to the low 16 MiB instead of running at 0x01xxxxxx. Plus the cases the reference disagrees on or the RTL does not model, each named with its reference: the 0x29 address-mode field that MAME's PC-9801 uses to decide whether the counter carries across a 64 KiB page is latched and never applied, so a block crossing 0xFFFF carries into the bank byte where MAME's default wraps within the page; single-transfer mode moves the whole block for a held DRQ where the 8237 moves one byte per request; and there is no memory-to-memory mode, so a VRAM-to-VRAM blit cannot be programmed.
//
// WHERE THE EXPECTATIONS COME FROM, so a later lane can re-derive each one.
//
// NP2kai's engine is mem/dmax86.c (and mem/dmav30.c), NOT io/dmac.c: io/dmac.c is the
// register file and the device procs, and dmax86 is the byte loop the two share:
//
//     if (!ch->leng.w) { dmac.stat |= bit; dmac.working &= ~bit; ... }
//     ch->leng.w--;
//     switch(ch->mode & 0x0c) {
//         case 0x00: ch->proc.inproc();                          break;  // verify
//         case 0x04: MEMP_WRITE8(adrs, ch->proc.inproc());       break;  // port->mem
//         default:   ch->proc.outproc(MEMP_READ8(ch->adrs.d));           // mem->port
//     }
//     ch->adrs.d += ((ch->mode & 0x20) ? -1 : 1);
//
// Four things fall out and every byte case below is measured against them: mode bits 3:2
// pick the direction with 10 and 11 both mem->port and 01 port->mem; bit 5 decrements;
// the address is incremented by the WHOLE 32-bit value, bank byte included; and the count
// test runs BEFORE the decrement, so a programmed count of N moves N+1 bytes (io/dmac.c's
// own dmac_getdatas helper uses N, but the engine that actually runs during a transfer is
// dmax86, and NP2kai's sound code sizes a buffer with startcount+1 -- NP2kai/cbus/cs4231io.c
// and sound/cs4231c.c settle it as N+1). The register file is io/dmac.c: the shared flip-flop
// toggles on every address/count access, and the bank byte at 0x21-0x27 lands on channel
// `((port >> 1) + 1) & 3`, so 0x21 is channel 1 and 0x27 is channel 0.
//
// MAME's PC-9801 (references/mame/pc9801.cpp:1298 dma_read_byte / :1324 dma_write_byte,
// and the 0x29 write at :90 dmapg8_w / :84 dmapg4_w) splits the address: the 8237's own
// 16-bit counter walks A0-A15 and WRAPS at 0xFFFF, while the high byte at 0x21-0x27 is a
// separate register that only moves at that wrap and only per the 0x29 address-mode field
// (`m_dma_autoinc`, reset to 0 at :1796): mode 1 increments its low nibble, mode 3 the whole
// byte, and modes 0 and 2 leave it frozen, so the transfer wraps within the 64 KiB page.
// The RTL carries into the bank byte on every byte, which is MAME's mode 3 for all modes.
//
// KF8237 (refs/PCXT_MiSTer/.../KF8237_Priority_Encoder.sv:140-176) is the tree's chosen
// 8237: SINGLE and BLOCK are edge-request (a byte sets a lock cleared only when DREQ drops,
// so a held DREQ yields ONE byte), DEMAND is level (a held DREQ streams). The RTL ignores
// mode bits 6:5 and is level for all three.
//
// WHAT THIS DOES NOT SETTLE. Whether the machine's default 0x29 field is 0 (MAME resets it
// to 0; NP2kai never reads it) -- so whether the carry the RTL does is ever wrong in
// practice is open, and the bench asserts the RTL's carry as its baseline while naming the
// divergence.

module tb_pc9821_dma_vram;

  // ==== DUT ====
  reg        clk = 0;
  reg        reset = 1;
  reg        sel = 0, write = 0;
  reg [4:0]  idx = 0;
  reg [7:0]  din = 0;
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

  // ==== the memory backend on the bus-master port ====
  // The same shape tb_pc9821_dmac_engine uses and the one the subsystem presents: the
  // accept is a LEVEL that answers the request in its own cycle, the produced word is a
  // register loaded at the accept and visible only at a SEPARATE completion pulse LATENCY
  // cycles later, and it starts at a SENTINEL so a read sampled at the accept is nameable.
  // A byte at 0xA8000 must reach index 0x0A8000, so the array covers 2 MiB; mem_be picks
  // the lane the same way src/memory/sdram.v does (addr[1:0] ignored there), and the write
  // byte is replicated into every lane on the way in.
  localparam integer LATENCY = 4;
  localparam [31:0]  SENTINEL = 32'hA5A5A5A5;
  reg [7:0]  mem [0:2097151];
  reg [31:0] produced = SENTINEL;
  reg [3:0]  pend = 0;
  // The full 32-bit address of every accepted request, so a case can pin WHERE a
  // transfer ran even when the 2 MiB array aliases the byte: B1 separates
  // 0x000A0001 from its stale-upper-bit twin 0x010A0001, which hold the same
  // byte here and differ only in the bits the bank write must zero.
  reg [31:0] req_addr [0:7];
  integer    req_n = 0;
  wire acc_now = mem_req && (pend == 0);
  always @(posedge clk) begin
    mem_resp_valid <= 1'b0;
    if (acc_now) begin
      req_addr[req_n[2:0]] <= mem_addr;
      req_n                <= req_n + 1;
      if (!mem_we) begin
        produced <= {4{mem[mem_addr[20:0]]}};
        pend     <= LATENCY;
      end else begin
        mem[mem_addr[20:0]] <= mem_din[7:0];
      end
    end else if (pend != 0) begin
      pend <= pend - 1;
      if (pend == 1) mem_resp_valid <= 1'b1;
    end
  end
  assign mem_ready = acc_now;
  always @(*) mem_dout = produced;

  // A byte transfer drives exactly one lane, and the lane is the address's low bits.
  always @(posedge clk)
    if (mem_req) begin
      if ((mem_be != 4'b0001) && (mem_be != 4'b0010) &&
          (mem_be != 4'b0100) && (mem_be != 4'b1000))
        $fatal(1, "the DMA drove byte lane %b, which is not one byte", mem_be);
      if (mem_be != (4'b0001 << mem_addr[1:0]))
        $fatal(1, "the DMA drove byte lane %b for address low bits %b, which disagree",
               mem_be, mem_addr[1:0]);
      if ((mem_din[7:0] != mem_din[15:8]) || (mem_din[15:8] != mem_din[23:16]) ||
          (mem_din[23:16] != mem_din[31:24]))
        $fatal(1, "the DMA's write byte is not replicated across lanes: %08x", mem_din);
    end

  // ==== the device stub ====
  // dev_din presents the next byte and advances only when the controller takes one, so the
  // byte the controller latches is the byte that was on the bus during its strobe.
  reg [7:0] dev_seq [0:63];
  integer   dev_n = 0;
  assign dev_din = dev_seq[dev_n[5:0]];
  reg [7:0] got [0:63];
  integer   got_n = 0;      // bytes the device GAVE the controller (mem->port)
  integer   tc_n = 0;
  always @(posedge clk) begin
    if (dev_stb && dev_we) begin got[got_n[5:0]] <= dev_dout; got_n <= got_n + 1; end
    if (dev_stb && !dev_we && dev_n < 63) dev_n <= dev_n + 1;
    if (dev_tc) tc_n <= tc_n + 1;
  end

  // ==== CHECKS ====
  integer errors = 0;        // the RTL contradicts a reference the bench treats as settled
  integer diverge = 0;       // the references disagree or the feature is not modelled
  task automatic note(input string what);
    begin $display("  note: %0s", what); end
  endtask
  task automatic check(input ok, input string what);
    begin
      if (!ok) begin
        errors = errors + 1;
        $display("FAIL %0s", what);
      end
    end
  endtask
  task automatic divergence(input string what);
    begin
      diverge = diverge + 1;
      $display("DIVERGENCE %0s", what);
    end
  endtask

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

  // The bank byte's channel: NP2kai's `((port >> 1) + 1) & 3` on ports 0x21/0x23/0x25/0x27
  // (idx 16..19) sends 0x27 to channel 0 and 0x21 to channel 1. The RTL's
  // `idx[1:0] + 1` wraps the same way, so channel c is idx 16 + ((c + 3) & 3).
  function [4:0] bank_idx(input [1:0] c); bank_idx = 5'd16 + {3'b000, (c + 2'd3)}; endfunction

  // Program one channel through the real flip-flop. 0x19 clears the flip-flop first, so the
  // two address writes take the low then the high half whatever parity the last case left;
  // the mode write and the bank write do NOT move it (only 0x01-0x0F do). A count write also
  // clears that channel's status bit, and 0x15 unmasks only this channel.
  task automatic setup_ch(input [1:0] c, input [23:0] a, input [15:0] cnt, input [7:0] mode);
    begin
      reg_wr(5'd12, 8'h00);                         // clear flip-flop
      reg_wr(5'd11, (mode & 8'hFC) | {6'b0, c});    // mode, channel in bits 1:0
      reg_wr({c, 1'b0}, a[7:0]);
      reg_wr({c, 1'b0}, a[15:8]);
      reg_wr({c, 1'b0} + 5'd1, cnt[7:0]);
      reg_wr({c, 1'b0} + 5'd1, cnt[15:8]);
      reg_wr(bank_idx(c), a[23:16]);
      reg_wr(5'd10, {6'b0, c});                     // unmask channel c
    end
  endtask

  task automatic cold();
    begin reg_wr(5'd13, 8'h00); end   // master clear: mask all, zero every address/count
  endtask

  task automatic run(input [3:0] req, input integer cycles);
    begin
      @(negedge clk); drq = req;
      repeat (cycles) @(negedge clk);
      drq = 4'b0000;
      repeat (4) @(negedge clk);
    end
  endtask

  task automatic fill(input [23:0] a, input [7:0] base);
    integer j;
    begin for (j = 0; j < 16; j = j + 1) mem[a + j[23:0]] = base + j[7:0]; end
  endtask

  integer i, j;
  integer before_got;

  initial begin
    // All regions the cases touch are zeroed; everything else is untouched and not read.
    for (i = 0; i <= 32'h01FFFF; i = i + 1) mem[i] = 8'h00;
    for (i = 32'h0A8000; i <= 32'h0A8FFF; i = i + 1) mem[i] = 8'h00;
    for (i = 32'h0B0000; i <= 32'h0B0FFF; i = i + 1) mem[i] = 8'h00;
    for (i = 0; i < 64; i = i + 1) begin dev_seq[i] = 8'hC0 + i[7:0]; got[i] = 8'h00; end

    repeat (8) @(negedge clk);
    reset = 1'b0;
    repeat (4) @(negedge clk);

    // ---- R1: the register file the bank cases depend on -------------------------
    // NP2kai dmac_o01/dmac_i01: one shared flip-flop, low half then high half. A bank write
    // must reach address bits 23:16 and NOT the low 16 bits.
    cold();
    reg_wr(5'd0, 8'h34); reg_wr(5'd0, 8'h12);
    reg_rd(5'd0); check(rd_val === 8'h34, $sformatf("R1: ch0 address low read %02x, NP2kai dmac_i01 returns 34", rd_val));
    reg_rd(5'd0); check(rd_val === 8'h12, $sformatf("R1: ch0 address high read %02x, NP2kai dmac_i01 returns 12", rd_val));
    reg_wr(bank_idx(2'd0), 8'h0A);
    reg_rd(bank_idx(2'd0));
    check(rd_val === 8'h0A, $sformatf("R1: 0x27 bank byte for ch0 read %02x, NP2kai dmac_o21 stores %02x (0x27 -> ((0x27>>1)+1)&3 = ch0)", rd_val, 8'h0A));
    reg_wr(bank_idx(2'd1), 8'h0B);
    reg_rd(bank_idx(2'd1));
    check(rd_val === 8'h0B, $sformatf("R1: 0x21 bank byte for ch1 read %02x, NP2kai dmac_o21 stores %02x (0x21 -> ch1)", rd_val, 8'h0B));
    reg_rd(bank_idx(2'd0));
    check(rd_val === 8'h0A, $sformatf("R1: the ch1 bank write disturbed ch0's byte (%02x)", rd_val));

    // ---- T1: memory -> I/O on channel 0, NP2kai dmax86 default (mem->port) ------
    cold();
    fill(24'h000100, 8'h80);
    setup_ch(2'd0, 24'h000100, 16'h0003, 8'h08);  // type 10, increment, demand
    got_n = 0; tc_n = 0;
    run(4'b0001, 120);
    check(got_n == 4, $sformatf("T1: a count of 3 moved %0d bytes, NP2kai dmax86 moves N+1 = 4", got_n));
    for (j = 0; j < 4; j = j + 1)
      check(got[j] === (8'h80 + j[7:0]), $sformatf("T1: byte %0d is %02x, mem[0x100+%0d] is %02x", j, got[j], j, 8'h80 + j[7:0]));
    check(tc_n == 1, $sformatf("T1: terminal count asserted %0d times, expected 1", tc_n));

    // ---- T2: I/O -> memory on channel 0, NP2kai dmax86 case 0x04 ---------------
    cold();
    setup_ch(2'd0, 24'h000200, 16'h0003, 8'h04);  // type 01, increment, demand
    dev_n = 0; tc_n = 0;
    run(4'b0001, 120);
    for (j = 0; j < 4; j = j + 1)
      check(mem[24'h000200 + j] === (8'hC0 + j[7:0]),
            $sformatf("T2: mem[0x200+%0d] is %02x, NP2kai dmax86 MEMP_WRITE8 stores %02x", j, mem[24'h000200 + j], 8'hC0 + j[7:0]));
    check(mem[24'h000204] === 8'h00, "T2: a fifth byte was written, so the count is N not N+1");

    // ---- T3/T4/T5: every remaining channel moves bytes in the memory direction --
    // Each channel is driven with only its own DRQ so the arbiter's choice is not in play.
    cold();
    fill(24'h000300, 8'h90);
    setup_ch(2'd1, 24'h000300, 16'h0002, 8'h08);
    got_n = 0;
    run(4'b0010, 120);
    check(got_n == 3 && got[0] === 8'h90 && got[2] === 8'h92,
          $sformatf("T3: channel 1 moved %0d bytes starting %02x, expected 3 from 0x300 (8'h90)", got_n, got[0]));

    cold();
    fill(24'h000400, 8'hA0);
    setup_ch(2'd2, 24'h000400, 16'h0001, 8'h08);
    got_n = 0;
    run(4'b0100, 120);
    check(got_n == 2 && got[0] === 8'hA0 && got[1] === 8'hA1,
          $sformatf("T4: channel 2 moved %0d bytes (%02x,%02x), expected 2 from 0x400", got_n, got[0], got[1]));

    cold();
    fill(24'h000500, 8'hB0);
    setup_ch(2'd3, 24'h000500, 16'h0000, 8'h08);
    got_n = 0;
    run(4'b1000, 120);
    check(got_n == 1 && got[0] === 8'hB0,
          $sformatf("T5: channel 3 moved %0d bytes (%02x), expected 1 from 0x500 (count 0 is one byte)", got_n, got[0]));

    // ---- T6: I/O -> memory on a non-zero channel, and the lane follows the addr --
    cold();
    setup_ch(2'd2, 24'h000601, 16'h0001, 8'h04);  // address low bits 01 -> lane 1
    dev_n = 0;
    run(4'b0100, 120);
    check(mem[24'h000601] === 8'hC0 && mem[24'h000602] === 8'hC1,
          $sformatf("T6: channel 2 wrote (%02x,%02x) at 0x601, expected C0,C1", mem[24'h000601], mem[24'h000602]));
    check(mem[24'h000600] === 8'h00, "T6: the odd start wrote the byte below the address (lane not from mem_addr[1:0])");

    // ---- S1: the SOUND/SAMPLE channel -------------------------------------------
    // The card that runs DMA on this machine is the WSS/CS4231 (and the SB16), and NP2kai's
    // cs4231dma[] = {0xff,0,1,3,0xff,0,1,3} (cbus/cs4231io.c:11) puts it on channel 0, 1 or 3 --
    // never channel 2, which the FDC takes. Playback is mem->I/O: cs4231_dma pulls a sound
    // buffer through dmax86. This drains a 16-byte block on channel 1 the same way.
    cold();
    fill(24'h000E00, 8'h20);
    setup_ch(2'd1, 24'h000E00, 16'h000F, 8'h08);  // mem->I/O, increment, demand
    got_n = 0; tc_n = 0;
    run(4'b0010, 400);
    check(got_n == 16, $sformatf("S1: the sound channel moved %0d bytes, a programmed count of 15 is 16", got_n));
    for (j = 0; j < 16; j = j + 1)
      check(got[j] === (8'h20 + j[7:0]),
            $sformatf("S1: sound byte %0d is %02x, mem[0xE00+%0d] is %02x", j, got[j], j, 8'h20 + j[7:0]));
    check(tc_n == 1, $sformatf("S1: the sound block asserted terminal count %0d times", tc_n));

    // ---- A1: autoinitialize reloads both halves and does not mask -----------------
    // NP2kai's engine does NOT reload (dmax86 clears `working` and never restores adrs/leng);
    // the 8237 does, via the base registers. The bench follows the chip: whole blocks repeat
    // and the byte pattern restarts, which a channel that masked itself at TC cannot do.
    cold();
    mem[24'h000700] = 8'hE1; mem[24'h000701] = 8'hE2;
    setup_ch(2'd0, 24'h000700, 16'h0001, 8'h18);  // type 10, autoinitialize
    got_n = 0;
    run(4'b0001, 120);
    check(got_n >= 4 && (got_n % 2) == 0,
          $sformatf("A1: autoinitialize moved %0d bytes, expected whole two-byte blocks (>=4)", got_n));
    check(got[0] === 8'hE1 && got[1] === 8'hE2 && got[2] === 8'hE1,
          $sformatf("A1: the second block did not restart at 0x700 (%02x,%02x,%02x)", got[0], got[1], got[2]));

    // ---- A2: autoinitialize reloads the BANK byte too ----------------------------
    // The block starts on the last byte of bank 0x0A and its second byte is in bank 0x0B, so
    // the live address carries into the bank byte. If autoinitialize restores only A0-A15 the
    // second block would read 0x0B0001 and hand the device 0x00; the pattern repeating proves
    // the reload covers bits 23:16 (the RTL's ch_addr_org holds them; NP2kai's dmac_o21 writes
    // adrs only and its dmax86 never reloads at all, so this is the 8237 behaviour, not NP2kai's).
    cold();
    mem[24'h0AFFFF] = 8'hD1; mem[24'h0B0000] = 8'hD2;
    setup_ch(2'd0, 24'h0AFFFF, 16'h0001, 8'h18);  // mem->I/O, autoinitialize
    got_n = 0;
    run(4'b0001, 160);
    check(got_n >= 4 && (got_n % 2) == 0,
          $sformatf("A2: the banked autoinitialize moved %0d bytes, expected whole two-byte blocks", got_n));
    check(got[0] === 8'hD1 && got[1] === 8'hD2 && got[2] === 8'hD1 && got[3] === 8'hD2,
          $sformatf("A2: the second block is (%02x,%02x), expected D1,D2 -- the bank byte did not reload", got[2], got[3]));

    // ---- D1: the decrement bit walks the address down ----------------------------
    cold();
    mem[24'h000803] = 8'hF1; mem[24'h000804] = 8'hF2;
    setup_ch(2'd0, 24'h000804, 16'h0001, 8'h28);  // type 10, decrement
    got_n = 0;
    run(4'b0001, 120);
    check(got_n == 2 && got[0] === 8'hF2 && got[1] === 8'hF1,
          $sformatf("D1: decrement moved (%02x,%02x) from 0x804, expected F2,F1", got_n ? got[0] : 8'hxx, got_n > 1 ? got[1] : 8'hxx));

    // ---- V1: an I/O -> memory transfer TARGETED AT VRAM (0x0A8000) ---------------
    // The bank byte reaches bits 23:16, so the byte must land at 0xA8000 and NOT at 0x8000.
    // This is the "does a DMA write to VRAM land correctly" case at the DMAC's own port.
    cold();
    setup_ch(2'd0, 24'h0A8000, 16'h0003, 8'h04);
    dev_n = 0;
    run(4'b0001, 120);
    for (j = 0; j < 4; j = j + 1)
      check(mem[24'h0A8000 + j] === (8'hC0 + j[7:0]),
            $sformatf("V1: VRAM byte %0d at 0xA8000 is %02x, the device sent %02x", j, mem[24'h0A8000 + j], 8'hC0 + j[7:0]));
    check(mem[24'h000800] === 8'h00,
          "V1: the write landed at 0x8000 as well, so the bank byte is not reaching bits 23:16");

    // ---- V2: a memory -> I/O transfer reading a VRAM address ---------------------
    cold();
    fill(24'h0A8010, 8'h70);
    setup_ch(2'd0, 24'h0A8010, 16'h0003, 8'h08);
    got_n = 0;
    run(4'b0001, 120);
    check(got_n == 4 && got[0] === 8'h70 && got[3] === 8'h73,
          $sformatf("V2: reading 0xA8010 gave %0d bytes starting %02x, expected 4 starting 70", got_n, got[0]));

    // ---- V3: a banked address other than the VRAM bank, same mechanism -----------
    cold();
    setup_ch(2'd3, 24'h0B0000, 16'h0002, 8'h04);
    dev_n = 0;
    run(4'b1000, 120);
    check(mem[24'h0B0000] === 8'hC0 && mem[24'h0B0001] === 8'hC1 && mem[24'h0B0002] === 8'hC2,
          $sformatf("V3: bank 0x0B wrote (%02x,%02x,%02x), expected C0,C1,C2", mem[24'h0B0000], mem[24'h0B0001], mem[24'h0B0002]));

    // ---- P1: the page boundary, and the 0x29 address-mode field that is ignored ---
    // MAME splits the address: A0-A15 wrap at 0xFFFF and the high byte at 0x21-0x27 moves
    // only per 0x29's field. The RTL carries into the bank byte every byte, i.e. MAME's
    // mode 3 for all modes, so a byte after 0xFFFF lands at 0x10000 and NOT at 0x0000.
    cold();
    mem[24'h00FFFF] = 8'hE1; mem[24'h010000] = 8'hE2; mem[24'h000000] = 8'hE3;
    setup_ch(2'd0, 24'h00FFFF, 16'h0001, 8'h08);
    got_n = 0;
    run(4'b0001, 120);
    check(got_n == 2 && got[0] === 8'hE1,
          $sformatf("P1: the byte at 0xFFFF read %02x", got_n ? got[0] : 8'hxx));
    if (got_n > 1 && got[1] === 8'hE2)
      divergence($sformatf("P1: the byte after 0xFFFF came from 0x10000 (%02x). MAME pc9801.cpp dma_read_byte with m_dma_autoinc=0 (its reset value, :1796) wraps A0-A15 and leaves the bank byte frozen, so it reads 0x0000 -> E3. NP2kai dmax86 carries adrs.d and reads 0x10000 -> E2, and this RTL matches NP2kai. The RTL latches 0x29 into ch_bound and never applies it, so the field cannot select MAME's modes 0/1/2 at all.", got[1]));
    else
      check(got_n > 1 && got[1] === 8'hE3,
            $sformatf("P1: the byte after 0xFFFF is %02x, neither MAME's E3 nor NP2kai's E2", got_n > 1 ? got[1] : 8'hxx));
    reg_rd(5'd20);
    check(rd_val === 8'h00, $sformatf("P1: reading 0x29 after an autoinc 0 program returned %02x", rd_val));

    // ---- P2: 0x29 programmed to a non-zero address mode changes nothing ----------
    cold();
    reg_wr(5'd20, 8'h0C);   // MAME dmapg8_w: field = (data>>2)&3 = 3, channel 0
    reg_rd(5'd20);
    check(rd_val === 8'h03, $sformatf("P2: 0x29 readback after mode 3 is %02x, the RTL returns ch_bound[0] = 3", rd_val));
    divergence("P2: 0x29's address-mode field is latched into ch_bound but never read by the engine, so modes 1 (increment the 20-bit nibble only) and 3 (increment the bank byte) and 0/2 (freeze it) all produce the same carry. MAME pc9801.cpp:1298/1324 applies it; NP2kai dmax86 ignores it and the RTL matches NP2kai.");

    // ---- V4: verify mode touches no memory and consumes a device byte ------------
    cold();
    mem[24'h000900] = 8'h55;
    setup_ch(2'd0, 24'h000900, 16'h0003, 8'h00);  // type 00 = verify
    got_n = 0; before_got = dev_n; tc_n = 0;
    run(4'b0001, 120);
    check(mem[24'h000900] === 8'h55, "V4: verify mode wrote memory");
    check(dev_n - before_got == 4,
          $sformatf("V4: verify consumed %0d device bytes, NP2kai dmax86 case 0x00 calls inproc() once per byte (4)", dev_n - before_got));
    check(tc_n == 1, $sformatf("V4: verify asserted terminal count %0d times", tc_n));

    // ---- M1: memory-to-memory is not available ----------------------------------
    // There is no command register (NP2kai has none either), so mode bits 3:2 = 11 is not a
    // memory-to-memory select: NP2kai dmax86's `default:` arm reads memory and hands the byte
    // to the device, exactly as type 10 does. A VRAM-to-VRAM blit therefore cannot be
    // programmed. The 8237 datasheet has memory-to-memory behind the command register's bit 0;
    // neither NP2kai nor KF8237 (its Timing_And_Control.sv line ~268 is a `// TODO  Memory-to-
    // Memory`) implements it, so this is a capability gap, not a byte mismatch.
    cold();
    fill(24'h000A00, 8'h60);
    setup_ch(2'd0, 24'h000A00, 16'h0003, 8'h0C);  // type 11
    got_n = 0;
    run(4'b0001, 120);
    check(got_n == 4 && got[0] === 8'h60 && got[3] === 8'h63,
          $sformatf("M1: type 11 moved %0d bytes (%02x..), NP2kai dmax86 default arm does mem->port", got_n, got[0]));
    check(mem[24'h000A00] === 8'h60 && mem[24'h000A03] === 8'h63,
          "M1: type 11 modified memory, which neither NP2kai nor the RTL does");
    divergence("M1: mode bits 3:2 = 11 is not memory-to-memory. NP2kai dmax86 has no such arm and no command register exists here, so a VRAM->VRAM (or any memory->memory) blit cannot be programmed; the 8237 datasheet's memory-to-memory is behind the command register, which the PC-98 file does not expose.");

    // ---- P3: pacing - DEMAND streams for a held DRQ (all references agree) -------
    cold();
    fill(24'h000B00, 8'h30);
    setup_ch(2'd0, 24'h000B00, 16'h0003, 8'h08);  // demand
    got_n = 0;
    run(4'b0001, 120);
    check(got_n == 4, $sformatf("P3: demand mode moved %0d bytes for a held DRQ, expected 4", got_n));

    // ---- P4: pacing - SINGLE also streams, where KF8237 moves one byte -----------
    cold();
    fill(24'h000C00, 8'h40);
    setup_ch(2'd0, 24'h000C00, 16'h0003, 8'h48);  // single (bits 6:5 = 01)
    got_n = 0;
    run(4'b0001, 120);
    if (got_n == 4)
      divergence($sformatf("P4: single-transfer mode moved %0d bytes for a held DRQ. KF8237_Priority_Encoder.sv:140-176 makes SINGLE edge-request, so a byte sets a lock cleared only when DREQ drops and a held DRQ yields ONE byte. NP2kai dmax86 and this RTL are level-triggered and move the whole block; the RTL never reads mode bits 6:5.", got_n));
    else
      check(got_n == 1, $sformatf("P4: single mode moved %0d bytes, expected KF8237's 1 or the block's 4", got_n));

    // ---- P5: pacing - BLOCK streams for a held DRQ ------------------------------
    cold();
    fill(24'h000D00, 8'h50);
    setup_ch(2'd0, 24'h000D00, 16'h0003, 8'h88);  // block (bits 6:5 = 10)
    got_n = 0;
    run(4'b0001, 120);
    check(got_n == 4, $sformatf("P5: block mode moved %0d bytes for a held DRQ, expected 4", got_n));

    // ---- P6: two channels requesting at once both finish, in priority order ------
    // NP2kai's dmax86 walks all four channels in one pass and moves ONE byte per working
    // channel, so ch0 and ch2 interleave; this RTL re-arbitrates after every byte and its
    // fixed priority (the S_IDLE loop keeps the LOWEST index) hands the whole bus to ch0
    // until it masks at terminal count. Both blocks still complete with the right bytes.
    cold();
    fill(24'h000F00, 8'h10);
    fill(24'h001000, 8'h60);
    setup_ch(2'd0, 24'h000F00, 16'h0003, 8'h08);
    setup_ch(2'd2, 24'h001000, 16'h0003, 8'h08);
    got_n = 0;
    run(4'b0101, 200);
    check(got_n == 8, $sformatf("P6: two requesting channels moved %0d bytes, expected 4+4", got_n));
    check(got[0] === 8'h10 && got[1] === 8'h11 && got[2] === 8'h12 && got[3] === 8'h13,
          $sformatf("P6: the first block is (%02x,%02x,%02x,%02x), expected 10,11,12,13", got[0], got[1], got[2], got[3]));
    check(got[4] === 8'h60 && got[5] === 8'h61 && got[6] === 8'h62 && got[7] === 8'h63,
          $sformatf("P6: the second block is (%02x,%02x,%02x,%02x), expected 60,61,62,63", got[4], got[5], got[6], got[7]));
    divergence("P6: a held DRQ on channel 0 starves channel 2 until ch0 masks at terminal count, so the two blocks arrive (10,11,12,13,60,61,62,63) rather than interleaved. NP2kai dmax86 loops all four channels per pass and moves one byte each, so it alternates 10,60,11,61,...; the byte SET is the same and only the interleave differs.");

    // ---- B1: a bank write zeroes the upper address bits (io/dmac.c:242) -----
    // NP2kai's dmac_o21 bank write stores the byte into adrs.b[DMA32_HIGH +
    // DMA16_LOW] and then ZEROES adrs.b[DMA32_HIGH + DMA16_HIGH] -- `= 0`, with
    // the comment that anything above bit 24 is unreachable without the 0x0E05
    // window (io/dmac.c:242). So after the engine's full-32-bit increment
    // (mem/dmax86.c:38, `ch->adrs.d += 1`) has carried OUT of bit 23, a later
    // bank reprogram must return the channel to the low 16 MiB. The expected
    // 0x000A0001 is NP2kai's rule applied to the walked state, NOT this RTL's:
    // FAIL-FIRST, keeping the stale carried bit gives 0x010A0001. The two hold
    // the same byte in the 2 MiB array, which is why the backend logs the full
    // request address.
    cold();
    reg_wr(5'd12, 8'h00);                         // clear flip-flop
    reg_wr(5'd11, 8'h08);                         // ch0 mode: mem->port, increment
    reg_wr(5'd0, 8'hFF); reg_wr(5'd0, 8'hFF);     // ch0 address low 16 = 0xFFFF
    reg_wr(5'd1, 8'h01); reg_wr(5'd1, 8'h00);     // ch0 count 1 = two bytes
    reg_wr(bank_idx(2'd0), 8'hFF);                // bank byte -> address 0xFFFFFF
    reg_wr(5'd10, 8'h00);                         // unmask channel 0
    req_n = 0;
    run(4'b0001, 120);
    check(req_n == 2, $sformatf("B1: the setup block moved %0d bytes, expected 2", req_n));
    check(req_addr[0] === 32'h00FFFFFF,
          $sformatf("B1: the setup block did not start at 0xFFFFFF (%08x)", req_addr[0]));
    check(req_addr[1] === 32'h01000000,
          $sformatf("B1: the increment did not carry out of bit 23 (%08x), NP2kai dmax86 adds to the whole adrs.d (mem/dmax86.c:38)", req_addr[1]));
    reg_wr(bank_idx(2'd0), 8'h0A);                // REPROGRAM the bank byte
    reg_wr(5'd1, 8'h00); reg_wr(5'd1, 8'h00);     // count 0 = one byte (a count write clears the TC)
    reg_wr(5'd10, 8'h00);                         // the TC masked the channel
    req_n = 0;
    run(4'b0001, 120);
    check(req_n == 1, $sformatf("B1: the second block moved %0d bytes, expected 1", req_n));
    check(req_addr[0] === 32'h000A0001,
          $sformatf("B1: after the bank reprogram the transfer ran at %08x; NP2kai's dmac_o21 zeroes adrs.b[31:24] on every bank write (io/dmac.c:242), so it must be 000A0001", req_addr[0]));

    // ==== VERDICT ====
    $display("DMA/VRAM: %0d byte-level mismatch(es), %0d reference divergence(s)", errors, diverge);
    if (diverge != 0)
      note("divergences are reported, not fixed: this bench is research + tests only");
    if (errors == 0) begin
      $display("TB_PC9821_DMA_VRAM: PASS");
      $finish;
    end
    else $fatal(1, "%0d DMA reference mismatch(es) plus %0d divergence(s)", errors, diverge);
  end

  // A bench that stops making progress names itself instead of hanging the runner.
  initial begin
    #8_000_000;
    $fatal(1, "the DMA/VRAM bench did not finish in 8 ms of simulated time");
  end

endmodule
