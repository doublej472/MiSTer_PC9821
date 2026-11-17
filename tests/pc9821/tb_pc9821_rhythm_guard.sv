`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_RHYTHM_GUARD:
// The rhythm loader's region bounds, which is where its own arithmetic can alias: waddr is offset[12:1], so a write one word past the region's end computes a word index that truncates to 0 -- it would overwrite ROM word 0, the first byte of the first percussion sample, on every pack download, using data from a region the loader does not own. The pack download walks the whole 1 MiB pack during the same stream, so the addresses on both sides of the region really do pass this module. The bench drives writes below the region, at its first and last words, one word past its end, and far past it, and requires that only the in-region words land, also while the loader's reset is held (as Main holds it while the pack streams: a region word written under reset lands at its own address and word 0 keeps its byte); the source of the layout is tools/build_pack.py's RHYTHM_OFFSET/RHYTHM_SIZE and its region tuple, which places the slot at 0x49000, 8192 bytes, between the extended banks ending at 0x49000 and the option-ROM slot at 0x70000.

// The DUT is the loader plus the ROM it fills, the same pair
// tb_pc9821_rhythm_rom drives: RHYTHM_ROM is the module jtopna instantiates
// (pc9821_dpram-backed, 12-bit words, byte read), so the byte the chip would
// read is the byte this bench reads through the ROM's own read port.
//
// WHY THIS IS A SEPARATE BENCH FROM tb_pc9821_rhythm_rom, which already covers
// the loader: that bench pins the INDEX guard (a stream under another ioctl
// index writes nothing) and the in-region contents byte for byte. It does not
// drive a single address OUTSIDE the region with the matching index, so the two
// ADDRESS guards -- ioctl_addr >= RHYTHM_PACK_OFFSET and offset < RHYTHM_BYTES
// -- are exercised by nothing. They are the guards that keep the loader out of
// ROM word 0, and the upper one is not redundant: offset[12:1] on offset 8192
// truncates to 0, which is a real alias rather than a discarded write.
//
// WHICH GUARD IS LOAD-BEARING, measured by removing each in turn:
//
//   * the UPPER bound (offset < RHYTHM_BYTES) is load-bearing. With it removed,
//     a write one word past the region lands on ROM word 0 and check 2 fails
//     naming the alias: "OVERWROTE ROM word 0 -- the alias, and offset[12:1]
//     truncating to 0 is its mechanism".
//   * the LOWER bound (ioctl_addr >= RHYTHM_PACK_OFFSET) is REDUNDANT. With it
//     removed every check still passes, because offset is a 27-bit subtraction
//     and an address below the region underflows to a value far above
//     RHYTHM_BYTES. It is kept as a defensive test, not because the width of
//     the subtraction is trusted to stay wide.
//
// Check 3 therefore pins the OUTCOME -- a write below the region must not land
// -- rather than the mechanism that currently achieves it, which is the right
// thing for a specification test to pin.
//
// No sample data appears anywhere in this file. The values streamed are the
// address's own low bits, so a wrong word index or a swapped byte pair changes
// the comparison; they are not a drum kit and are not committed as audio.

module tb_pc9821_rhythm_guard;
  reg clk = 0;
  always #5 clk = ~clk;

  localparam [26:0] REGION       = 27'h0049000;  // pack offset of the 8 KiB image
  localparam integer REGION_BYTES = 8192;
  localparam [26:0] PAST_REGION  = REGION + 27'd8192;   // first pack word after it
  localparam [26:0] WELL_PAST    = REGION + 27'h20000; // beyond, still in the pack

  // Watchdog: a bound, so a hang is a FAIL rather than a timeout.
  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_RHYTHM_GUARD: watchdog expired");
  end

  reg reset = 1;

  // Shared ROM-pack download stream (pc9821_system's ioctl_* ports).
  reg         ioctl_download = 0;
  reg  [15:0] ioctl_index = 0;
  reg         ioctl_wr = 0;
  reg  [26:0] ioctl_addr = 0;
  reg  [15:0] ioctl_dout = 0;

  // ==== DUT ====
  wire        rom_we;
  wire [11:0] rom_waddr;
  wire [15:0] rom_wdata;

  // The ROM's own read port, driven by the bench: the chip drives it from
  // jtopna in the design.
  reg  [12:0] rom_address = 0;
  reg         rom_rden = 0;
  wire  [7:0] rom_q;

  pc9821_rhythm_loader #(
      .IOCTL_INDEX(16'd0),
      .RHYTHM_PACK_OFFSET(REGION),
      .RHYTHM_BYTES(REGION_BYTES)
  ) loader (
      .clk(clk), .reset(reset),
      .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
      .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
      .we(rom_we), .waddr(rom_waddr), .wdata(rom_wdata)
  );

  RHYTHM_ROM rom (
      .address(rom_address), .clock(clk), .rden(rom_rden), .q(rom_q),
      .we(rom_we), .waddr(rom_waddr), .wdata(rom_wdata)
  );

  integer errors = 0;
  integer i;

  task automatic fail(input [8*160-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ---- helpers ----------------------------------------------------------
  // One pack word as the download delivers it: low byte at the even address.
  task automatic push_word(input [26:0] a, input [7:0] lo, input [7:0] hi);
    begin
      @(negedge clk);
      ioctl_download = 1'b1;
      ioctl_index    = 16'd0;
      ioctl_addr     = a;
      ioctl_dout     = {hi, lo};
      ioctl_wr       = 1'b1;
      @(posedge clk);
      @(negedge clk);
      ioctl_wr       = 1'b0;
      ioctl_download = 1'b0;
    end
  endtask

  // The byte the ROM answers at a byte address, through its own read port.
  // `address` is presented with rden high; q is valid the next clock.
  reg [7:0] got;
  task automatic read_rom(input [12:0] a, output [7:0] q);
    begin
      @(negedge clk);
      rom_address = a;
      rom_rden    = 1'b1;
      @(posedge clk);
      @(negedge clk);
      rom_rden    = 1'b0;
      q           = rom_q;
    end
  endtask

  // The byte the pack word at address `a` would put at ROM address `2W+0/1`.
  // A function of the address so an offset or byte-order error shows up.
  function automatic [7:0] lo_byte(input [26:0] a);
    lo_byte = {1'b0, a[6:0]} ^ 8'h5A;
  endfunction
  function automatic [7:0] hi_byte(input [26:0] a);
    hi_byte = {1'b0, a[13:7]} ^ 8'hC3;
  endfunction

  // Let the loader's one-cycle output registers settle before reading.
  task automatic settle;
    begin
      repeat (4) @(posedge clk);
    end
  endtask

  // ==== CHECKS ====
  reg [7:0] v;

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (4) @(posedge clk);

    // ---- 1. the region's first and last words both land ----------------
    // The extent this pins is INCLUSIVE: offset 0 and offset REGION_BYTES-2 are
    // the region's own words, so both must arrive. build_pack.py's tuple names
    // (RHYTHM_OFFSET, RHYTHM_OFFSET + RHYTHM_SIZE) as one region, and
    // RHYTHM_ROM holds word W at byte addresses 2W and 2W+1.
    push_word(REGION, lo_byte(REGION), hi_byte(REGION));
    push_word(REGION + 27'(REGION_BYTES - 2),
              lo_byte(REGION + 27'(REGION_BYTES - 2)),
              hi_byte(REGION + 27'(REGION_BYTES - 2)));
    settle;

    read_rom(13'd0, v);
    if (v !== lo_byte(REGION))
      fail("the region's first word did not land at ROM address 0");
    read_rom(13'd1, v);
    if (v !== hi_byte(REGION))
      fail("the region's first word's high byte is not at ROM address 1");
    read_rom(13'(REGION_BYTES - 2), v);
    if (v !== lo_byte(REGION + 27'(REGION_BYTES - 2)))
      fail("the region's LAST word did not land at the ROM's last addresses");
    read_rom(13'(REGION_BYTES - 1), v);
    if (v !== hi_byte(REGION + 27'(REGION_BYTES - 2)))
      fail("the region's last word's high byte is wrong");

    // ---- 2. a write ONE WORD PAST the region must not land --------------
    // This is the alias. The pack download walks the whole 1 MiB pack in the
    // same stream, so the word at REGION+8192 really is delivered to this
    // module with this index. Un-guarded, offset[12:1] on 8192 truncates to 0
    // and this write lands on ROM word 0 -- the first byte of the first
    // percussion sample -- destroying data the loader does not own.
    push_word(PAST_REGION, 8'hDE, 8'hAD);
    settle;
    read_rom(13'd0, v);
    if (v !== lo_byte(REGION))
      fail("a write past the region's end OVERWROTE ROM word 0 -- the alias, and offset[12:1] truncating to 0 is its mechanism");
    read_rom(13'd1, v);
    if (v !== hi_byte(REGION))
      fail("a write past the region's end overwrote ROM byte 1 (the same alias, high byte)");

    // ---- 3. a write BELOW the region must not land ----------------------
    // offset = ioctl_addr - RHYTHM_PACK_OFFSET wraps for an address below the
    // region, so the explicit ioctl_addr >= RHYTHM_PACK_OFFSET test is what
    // excludes it rather than the width of the subtraction.
    push_word(REGION - 27'd2, 8'hBE, 8'hEF);
    settle;
    read_rom(13'd0, v);
    if (v !== lo_byte(REGION))
      fail("a write BELOW the region landed in the ROM");
    read_rom(13'd1, v);
    if (v !== hi_byte(REGION))
      fail("a write below the region landed on ROM byte 1");

    // ---- 4. far past the region, and a second index ---------------------
    // Both remain excluded, and the ROM is unchanged, so the guard is a region
    // check rather than a distance check that happens to work nearby.
    push_word(WELL_PAST, 8'h11, 8'h22);
    settle;
    read_rom(13'd0, v);
    if (v !== lo_byte(REGION))
      fail("a write far past the region landed in the ROM");

    // A foreign index at an IN-REGION address must also do nothing, which is
    // the neighbouring bench's check; repeated here so this bench fails for
    // only one reason if the index test is ever weakened.
    @(negedge clk);
    ioctl_download = 1'b1;
    ioctl_index    = 16'd7;
    ioctl_addr     = REGION;
    ioctl_dout     = {8'h99, 8'h88};
    ioctl_wr       = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ioctl_wr       = 1'b0;
    ioctl_download = 1'b0;
    settle;
    read_rom(13'd0, v);
    if (v !== lo_byte(REGION))
      fail("a foreign-index write at an in-region address landed in the ROM");

    // ---- 5. the pack lands WHILE the loader's reset is held ----------------
    // That is how the pack really loads: Main holds the core's reset bit while it streams the
    // pack (tb_pc9821_raster_hold models the same hold), and the loader's reset copy is the raw
    // one, not gated by the pack-load hold. So a region word written under reset must land at
    // its own address with its own bytes, and must not leave a zero word behind at word 0.
    @(negedge clk);
    reset = 1'b1;
    push_word(REGION + 27'h100, lo_byte(REGION + 27'h100), hi_byte(REGION + 27'h100));
    settle;
    @(negedge clk);
    reset = 1'b0;
    settle;
    read_rom(13'h100, v);
    if (v !== lo_byte(REGION + 27'h100))
      fail("a region word written while reset is held did not land (low byte)");
    read_rom(13'h101, v);
    if (v !== hi_byte(REGION + 27'h100))
      fail("a region word written while reset is held did not land (high byte)");
    read_rom(13'd0, v);
    if (v !== lo_byte(REGION))
      fail("a download under reset overwrote ROM word 0");

  // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_RHYTHM_GUARD: PASS");
      $finish;
    end else begin
      $display("TB_PC9821_RHYTHM_GUARD: FAIL (%0d errors)", errors);
      $fatal(1, "TB_PC9821_RHYTHM_GUARD: FAIL (%0d errors)", errors);
    end
  end
endmodule
