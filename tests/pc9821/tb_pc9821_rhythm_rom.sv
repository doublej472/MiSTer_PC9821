`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The rhythm ROM's pack-loader path: a synthetic pack stream written through pc9821_rhythm_loader fills RHYTHM_ROM at pack offset 0x49000 with the exact bytes the stream carried (byte order and offsets included), a stream whose region is zero leaves the ROM reading zero (which is NOT silence -- the decoder ramps zero codes; this bench only pins the LOADER, not the audio), a download under another ioctl index writes nothing, and a region streamed while the core's reset is up still lands whole; the synthetic pattern differs in every 256-byte block, so a loader that moves whole blocks fails too. With +RHYTHM_REGION=<file> it additionally drives the region from the 4096 words build_pack.py wrote there in a real pack, so the loader is proved against the tooling's own output and not only a fixture. It does NOT use or assert any percussion sample data, and it does not claim the channel is audible without a user-supplied image.

// The DUT is the loader plus the ROM it fills. RHYTHM_ROM is the same module
// jtopna instantiates (pc9821_dpram-backed, 12-bit words, byte read), so the
// byte the chip would read is the byte this bench reads through the ROM's own
// read port. pc9821_system wires the loader's outputs into pc9821_opna ->
// jtopna -> RHYTHM_ROM; that wiring is a straight pass-through and is not
// re-derived here, because the ROM's contents are only observable through the
// read port the bench already owns.
//
// No sample data appears anywhere in this file. The synthetic pattern is a
// function of the pack address, chosen so a byte-order swap or an offset error
// changes the comparison; it is not a drum kit and is not committed as audio.

module tb_pc9821_rhythm_rom;
  reg clk = 0;
  always #5 clk = ~clk;

  localparam [26:0] REGION = 27'h0049000;   // pack offset of the 8 KiB image
  localparam integer REGION_BYTES = 8192;
  // The whole 1 MiB pack, not just the region's neighbourhood: the stream this
  // bench drives is pack-shaped, so a real pack's addresses on both sides of the
  // region (the extended banks below, the option-ROM slot and the font above)
  // all go past the loader and must not disturb the ROM.
  localparam [26:0] STREAM_END = 27'h0100000;

  reg reset = 1;

  // Shared ROM-pack download stream.
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

  task automatic fail(input [8*80-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // Recorded-result helper for a mismatch message that names the address.
  integer i;

  // The byte expected at each ROM address. Filled from the synthetic pattern,
  // or, in real-pack mode, from the words read out of the pack.
  reg  [7:0]   expected     [0:8191];
  reg  [15:0]  region_words [0:4095];
  reg  [1023:0] region_path;
  integer      have_region;

  // ==== STIMULUS ====
  // The byte the synthetic stream carries at pack offset p. A function of the
  // offset, so a wrong offset or a swapped byte pair changes the compared value.
  // The high offset bits enter too (p[12:8] times an odd 77, distinct mod 256), so
  // every 256-byte block of the region differs and a loader that shuffles, aliases
  // or inverts whole blocks (waddr's upper bits) cannot match.
  function automatic [7:0] pattern(input [26:0] p);
    pattern = 8'(p[7:0] + 8'h5A + 8'(p[12:8] * 8'd77));
  endfunction

  // One 16-bit pack word at even byte address `a`: the low byte is the byte at
  // `a`, the high byte the byte at `a+1`, which is how the download presents
  // them (pc9821_rom_loader's ioctl_dout split).
  task automatic push_word(input [26:0] a, input [7:0] b0, input [7:0] b1);
    begin
      @(negedge clk);
      ioctl_addr = a;
      ioctl_dout = {b1, b0};
      ioctl_wr   = 1'b1;
      @(negedge clk);
      ioctl_wr   = 1'b0;
    end
  endtask

  // Drive the whole 0 .. 1 MiB pack range with `pattern`, so words before the
  // region (which must not bleed in), inside it (which must land), and after it
  // (which must not disturb it) all go by.
  task automatic stream_pattern();
    reg [26:0] a;
    begin
      ioctl_download = 1'b1;
      ioctl_index    = 16'd0;
      for (a = 27'd0; a < STREAM_END; a = a + 27'd2)
        push_word(a, pattern(a), pattern(a + 27'd1));
      @(negedge clk);
      ioctl_download = 1'b0;
    end
  endtask

  // Drive only the region, every byte zero: the no-image pack's shape.
  task automatic stream_zero_region();
    reg [26:0] a;
    begin
      ioctl_download = 1'b1;
      ioctl_index    = 16'd0;
      for (a = REGION; a < STREAM_END; a = a + 27'd2)
        push_word(a, 8'h00, 8'h00);
      @(negedge clk);
      ioctl_download = 1'b0;
    end
  endtask

  // Read one ROM byte through the ROM's own read port (the chip's access).
  task automatic read_rom(input [12:0] a, output [7:0] v);
    begin
      @(negedge clk);
      rom_address = a;
      rom_rden    = 1'b1;
      @(negedge clk);
      v = rom_q;
    end
  endtask

  // ==== CHECKS ====
  reg [7:0] v, want;
  integer mismatches;

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (4) @(posedge clk);

    // ---- 1. a download under another ioctl index writes nothing ----------
    // The loader owns no bus and cannot stall the pack load, so the only thing
    // it must not do is react to a stream it does not own. Drive region words
    // under index 7 and require the ROM to stay zero.
    ioctl_download = 1'b1;
    ioctl_index    = 16'd7;
    for (i = 0; i < 16; i = i + 1)
      push_word(REGION + i * 27'd2, 8'hDE, 8'hAD);
    @(negedge clk);
    ioctl_download = 1'b0;
    mismatches = 0;
    for (i = 0; i < REGION_BYTES; i = i + 1) begin
      read_rom(i[12:0], v);
      if (v !== 8'h00) mismatches = mismatches + 1;
    end
    if (mismatches != 0)
      fail("a foreign-index download wrote into the rhythm ROM");

    // ---- 2. the region's bytes land, at the right offsets and order ------
    // Byte order is pinned by reading both bytes of a word: a swapped pair
    // would put the high byte at the low address. The offset is pinned by
    // driving the whole stream: an off-by-a-word load would compare against a
    // different address.
    //
    // By default the stream is the synthetic pattern. With
    // +RHYTHM_REGION=<file>, where <file> is a $readmemh of the 4096 16-bit
    // words build_pack.py wrote at the region (word W = {pack[0x49001+2W],
    // pack[0x49000+2W]}), the region is driven from a REAL pack's bytes
    // instead -- the loader is then checked against the tooling's own output
    // rather than only a fixture. The gate runs the synthetic path; the
    // real-pack path is run by hand when a pack is present.
    have_region = $value$plusargs("RHYTHM_REGION=%s", region_path);
    if (have_region) begin
      $readmemh(region_path, region_words);
      for (i = 0; i < REGION_BYTES/2; i = i + 1) begin
        expected[i*2]     = region_words[i][7:0];
        expected[i*2 + 1] = region_words[i][15:8];
      end
      ioctl_download = 1'b1;
      ioctl_index    = 16'd0;
      for (i = 0; i < REGION_BYTES/2; i = i + 1)
        push_word(REGION + i * 27'd2, region_words[i][7:0], region_words[i][15:8]);
      @(negedge clk);
      ioctl_download = 1'b0;
    end else begin
      for (i = 0; i < REGION_BYTES; i = i + 1)
        expected[i] = pattern(REGION + i);
      stream_pattern();
    end
    mismatches = 0;
    for (i = 0; i < REGION_BYTES; i = i + 1) begin
      read_rom(i[12:0], v);
      want = expected[i];
      if (v !== want) begin
        if (mismatches < 4)
          $display("FAIL: ROM[%0d] = %02x, expected %02x", i, v, want);
        mismatches = mismatches + 1;
      end
    end
    if (mismatches != 0)
      fail("pack region did not fill the rhythm ROM byte for byte");

    // The boundaries named explicitly, so a failure that only clips the ends
    // is still reported: first word, last word, and the last byte.
    read_rom(13'd0, v);
    if (v !== expected[0]) fail("ROM[0] is not the region's first byte");
    read_rom(13'd1, v);
    if (v !== expected[1]) fail("ROM[1] byte order is wrong");
    read_rom(13'd8191, v);
    if (v !== expected[8191]) fail("ROM[last] is not the region's last byte");

    // ---- 3. a zeroed region leaves the ROM reading zero (no image) ------
    // The no-image pack zero-fills the region (tools/build_pack.py), and this
    // is the resulting state: every address answers 0x00. That is NOT silence
    // (an all-zero ADPCM-A code steps the decoder, AGENTS.md "Firmware pack");
    // this bench pins only that the ROM follows the pack, not the audio.
    stream_zero_region();
    mismatches = 0;
    for (i = 0; i < REGION_BYTES; i = i + 1) begin
      read_rom(i[12:0], v);
      if (v !== 8'h00) mismatches = mismatches + 1;
    end
    if (mismatches != 0)
      fail("a zeroed region did not leave the rhythm ROM reading zero (which is NOT silence: the decoder ramps zero codes)");

    // ---- 4. a pack word that arrives while the core's reset is up still lands --
    // The pack download is the framework's, not the core's: hps_io streams it whatever
    // the core's reset does, and z486_mister keeps the SDRAM controller out of reset for
    // the load (`.reset(rst_top[T_SDRAM] && !pack_load_hold)`) for the same reason. So a
    // reset during the download may not cost the rhythm ROM a word.
    reset = 1;
    ioctl_download = 1'b1;
    ioctl_index    = 16'd0;
    for (i = 0; i < REGION_BYTES/2; i = i + 1)
      push_word(REGION + i * 27'd2, pattern(REGION + i * 2) ^ 8'hA5, pattern(REGION + i * 2 + 1) ^ 8'hA5);
    @(negedge clk);
    ioctl_download = 1'b0;
    reset = 0;
    mismatches = 0;
    for (i = 0; i < REGION_BYTES; i = i + 1) begin
      read_rom(i[12:0], v);
      if (v !== (pattern(REGION + i) ^ 8'hA5)) mismatches = mismatches + 1;
    end
    if (mismatches != 0)
      fail("pack words written while reset was up did not all land in the rhythm ROM");

  // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_RHYTHM_ROM: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_RHYTHM_ROM: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog.
  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_RHYTHM_ROM: TIMEOUT");
  end

endmodule
