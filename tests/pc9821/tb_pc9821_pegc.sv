`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_PEGC: the PEGC register file at 0xE0000 answers as NP2kai's memvgaio byte store does - bank A at 0xE0004 and bank B at 0xE0006 round-trip the full written byte while the exported bank value is the low nibble, 0xE0100 keeps bit 0 only (the packed/plane mode select) while 0xE0102 keeps the whole written byte with bit 0 exported as the flat-aperture VRAM enable, the plane engine's control registers 0xE0104-0xE011F round-trip as plain bytes with no engine consuming them, every other offset in the 32 KiB window reads 0x00 with its stores dropped, a dword read composes the four byte answers in little-endian lane order, and the responder never accepts and answers in one cycle. FAIL-FIRST: on the tree without pc9821_pegc there is no register file at all, so every read-back row fails.

// ==== DUT ====
// pc9821_pegc alone: the register file and its registered responder, driven on the
// dword-aligned byte-enable port pc9821_memory_subsystem will present.
//
// The expectations are NP2kai's memvgaio (mem/memvga.c) and the register map of
// io/pegc.h, cross-checked against the machine's own capture
// (docs/probes/PEGC.TXT: PPM bank A8 = 0xE0004 and PPM bank B0 = 0xE0006 are the
// two bank registers; DOOM set 0xE0006 = 0x01 and never touched 0xE0004). Where a
// reference disagrees it is named at the check and NOT asserted: MAME masks the
// bank write to 4 bits (pc9821.cpp pegc_mmio_map `data & 0xf`) where NP2kai stores
// the whole byte and masks at use, and MAME maps 0xE0100/0xE0102 write-only where
// NP2kai reads them back. Both divergences are capture-pending; the hierarchy
// default is NP2kai.

// ==== STIMULUS ====
// One CPU access per call on the responder's own protocol: hold valid until the
// accept, then release. Reads complete on the response pulse; a write completes at
// the accept. The address is DWORD-ALIGNED with byte enables, exactly the shape
// pc9821_memory_subsystem presents (z486's {z_addr, 2'b00} + z_be): a byte access
// to 0xE0006 is the dword 0xE0004 with be = 4'b0100, so the byte helpers below
// convert an offset into that pair and nothing about the caller's view is assumed.

module tb_pc9821_pegc;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  reg         cpu_valid = 0, cpu_write = 0, cpu_line_read = 0;
  reg  [14:0] cpu_addr = 0;
  reg  [31:0] cpu_din = 0;
  reg  [3:0]  cpu_be = 4'hF;
  wire [31:0] cpu_dout;
  wire        cpu_ready, cpu_resp_valid, cpu_line_word_valid;
  wire [3:0]  bank_a, bank_b;
  wire        plane_mode, vram_en;

  pc9821_pegc dut (
      .clk(clk), .reset(reset),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write), .cpu_line_read(cpu_line_read),
      .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_be(cpu_be),
      .cpu_dout(cpu_dout),
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .bank_a(bank_a), .bank_b(bank_b),
      .plane_mode(plane_mode), .vram_en(vram_en)
  );

  integer errors = 0;

  // Bound: a route that stops answering is a FAIL, not a stall.
  initial begin
    #200_000;
    $fatal(1, "TB_PC9821_PEGC: FAIL watchdog (the stimulus did not finish)");
  end

  // Accept and response in the same cycle is the z486 hazard the responder
  // contract forbids: assert it on every cycle, not only at the checks.
  always @(posedge clk) begin
    if (!reset && cpu_ready && cpu_resp_valid)
      $fatal(1, "TB_PC9821_PEGC: accept and response in one cycle");
  end

  task automatic cpu_store(input [14:0] a, input [31:0] d, input [3:0] be);
    integer g;
    begin
      @(negedge clk);
      cpu_addr = a; cpu_din = d; cpu_be = be; cpu_write = 1; cpu_line_read = 0;
      cpu_valid = 1;
      g = 0; while (!cpu_ready && g < 40) begin @(negedge clk); g = g + 1; end
      if (!cpu_ready) $fatal(1, "TB_PC9821_PEGC: no accept for write %04x", a);
      @(negedge clk); cpu_valid = 0; cpu_write = 0;
    end
  endtask

  task automatic cpu_load(input [14:0] a, output [31:0] d);
    integer g;
    begin
      @(negedge clk);
      cpu_addr = a; cpu_din = 32'd0; cpu_be = 4'hF; cpu_write = 0; cpu_line_read = 0;
      cpu_valid = 1;
      g = 0; while (!cpu_ready && g < 40) begin @(negedge clk); g = g + 1; end
      if (!cpu_ready) $fatal(1, "TB_PC9821_PEGC: no accept for read %04x", a);
      g = 0; while (!cpu_resp_valid && g < 40) begin @(negedge clk); g = g + 1; end
      if (!cpu_resp_valid) $fatal(1, "TB_PC9821_PEGC: no response for read %04x", a);
      d = cpu_dout;
      @(negedge clk); cpu_valid = 0;
    end
  endtask

  // A byte store/load at window offset `off`: the dword pair the requester sends.
  task automatic store_byte(input [14:0] off, input [7:0] dat);
    begin
      cpu_store(off & 15'h7FFC, {24'd0, dat} << (8 * (off & 2'd3)),
                4'b0001 << (off & 2'd3));
    end
  endtask

  task automatic load_byte(input [14:0] off, output [7:0] dat);
    reg [31:0] word;
    begin
      cpu_load(off & 15'h7FFC, word);
      dat = word[8 * (off & 2'd3) +: 8];
    end
  endtask

  task automatic expect_byte(input [14:0] off, input [7:0] want,
                             input [8*96-1:0] what);
    reg [7:0] got;
    begin
      load_byte(off, got);
      if (got !== want) begin
        $display("FAIL: %0s: [%04x] read %02x, want %02x", what, off, got, want);
        errors = errors + 1;
      end
    end
  endtask

  task automatic expect_rd(input [14:0] a, input [31:0] want, input [8*96-1:0] what);
    reg [31:0] got;
    begin
      cpu_load(a, got);
      if (got !== want) begin
        $display("FAIL: %0s: [%04x] read %08x, want %08x", what, a, got, want);
        errors = errors + 1;
      end
    end
  endtask

  reg [31:0] rd;

  // ==== CHECKS ====
  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;

    // ---- 1. the bank registers (NP2kai memvga.h PPM_BANK_A8/B0, memvga.c VGARD8) ----
    // Full-byte round-trip (NP2kai stores `value` verbatim and masks & 15 at USE);
    // MAME masks the write to 4 bits, recorded not asserted.
    store_byte(15'h0004, 8'hAB);
    store_byte(15'h0006, 8'h05);
    expect_byte(15'h0004, 8'hAB, "bank A byte round-trips (NP2kai mio1)");
    expect_byte(15'h0006, 8'h05, "bank B byte round-trips (NP2kai mio1)");
    if (bank_a !== 4'hB) begin
      $display("FAIL: bank_a exported %x, want b (the nibble NP2kai banks on)", bank_a);
      errors = errors + 1;
    end
    if (bank_b !== 4'h5) begin
      $display("FAIL: bank_b exported %x, want 5", bank_b);
      errors = errors + 1;
    end
    // The capture's own values: DOOM set 0xE0006 = 01 and left 0xE0004 at 00
    // (docs/probes/PEGC.TXT PLREG rows).
    store_byte(15'h0004, 8'h00);
    store_byte(15'h0006, 8'h01);
    if (bank_a !== 4'h0 || bank_b !== 4'h1) begin
      $display("FAIL: DOOM's bank values exported %x/%x, want 0/1", bank_a, bank_b);
      errors = errors + 1;
    end

    // ---- 2. mode 0xE0100: bit 0 ONLY (NP2kai memvgaio_wr8 `value &= 0x1`) ----
    store_byte(15'h0100, 8'hFF);
    expect_byte(15'h0100, 8'h01, "0xE0100 keeps bit 0 only");
    if (plane_mode !== 1'b1) begin
      $display("FAIL: plane_mode not set by [0xE0100] = FF");
      errors = errors + 1;
    end
    store_byte(15'h0100, 8'h00);
    expect_byte(15'h0100, 8'h00, "0xE0100 clears");
    if (plane_mode !== 1'b0) begin
      $display("FAIL: plane_mode stuck after [0xE0100] = 0");
      errors = errors + 1;
    end

    // ---- 3. VRAM enable 0xE0102: the whole byte stores (NP2kai), bit 0 gates ----
    store_byte(15'h0102, 8'hFF);
    expect_byte(15'h0102, 8'hFF, "0xE0102 round-trips the full byte (NP2kai)");
    if (vram_en !== 1'b1) begin
      $display("FAIL: vram_en not set by [0xE0102] = FF");
      errors = errors + 1;
    end
    store_byte(15'h0102, 8'h00);
    if (vram_en !== 1'b0) begin
      $display("FAIL: vram_en stuck after [0xE0102] = 0");
      errors = errors + 1;
    end

    // ---- 4. the engine's control registers: plain byte storage, no engine ----
    store_byte(15'h0104, 8'h5A);
    store_byte(15'h0118, 8'hA5);
    expect_byte(15'h0104, 8'h5A, "0xE0104 (plane inhibit) round-trips");
    expect_byte(15'h0118, 8'hA5, "0xE0118 (palette2) round-trips");
    // A dword write hits four consecutive byte registers in lane order.
    cpu_store(15'h010C, 32'h1122_3344, 4'hF);
    expect_rd(15'h010C, 32'h1122_3344, "0xE010C (pixel mask) stores four lanes");
    // A partial write moves only its own lane.
    cpu_store(15'h010C, 32'h0000_00EE, 4'b0001);
    expect_rd(15'h010C, 32'h1122_33EE, "byte-lane write touches one byte");

    // ---- 5. a dword read composes the byte answers little-endian ----
    store_byte(15'h0004, 8'hAB);
    store_byte(15'h0005, 8'hCD);
    store_byte(15'h0006, 8'h05);
    expect_rd(15'h0004, 32'h0005_CDAB, "dword at 0xE0004 = {mio1[3..0]}");

    // ---- 6. the recorded gaps and the dropped-store arms ----
    // The pattern block 0xE0120-0xE019F is L3's (the engine's ROP source) and is
    // NOT built: this answers 0x00 there (NP2kai's own uncovered-position
    // answer). NP2kai's memvgaio would return its pattern view at the aligned
    // positions - recorded as the L3 gap, not asserted as the machine's answer.
    cpu_store(15'h0120, 32'h0000_0077, 4'h1);
    expect_rd(15'h0120, 32'h0000_0000, "pattern block is not built (L3, recorded gap)");
    // Every other offset: 0x00 reads, stores dropped (NP2kai memvgaio_rd8's
    // `return 0x00`, memvgaio_wr8's fall-through).
    store_byte(15'h0000, 8'h99);
    expect_byte(15'h0000, 8'h00, "0xE0000 reads 0x00");
    store_byte(15'h0008, 8'h99);
    expect_byte(15'h0008, 8'h00, "0xE0008 (no register) reads 0x00");
    store_byte(15'h01A0, 8'h99);
    expect_byte(15'h01A0, 8'h00, "0xE01A0 (past the pattern) reads 0x00");

    // ---- 7. a line read is answered as FOUR word beats, not stalled (no hang for an
    // ---- icache fill): each beat is the register file's dword, repeated (P3 deleted the
    // ---- 128-bit `{4{cpu_dout}}` copy; the beats are the word response itself) ----
    @(negedge clk);
    cpu_addr = 15'h0004; cpu_be = 4'hF; cpu_write = 0; cpu_line_read = 1; cpu_valid = 1;
    begin : line_probe
      integer g, beats;
      reg seen_ready;
      seen_ready = 0; beats = 0;
      for (g = 0; g < 40; g = g + 1) begin
        @(negedge clk);
        if (cpu_ready) seen_ready = 1;
        if (cpu_resp_valid) begin
          beats = beats + 1;
          if (cpu_dout !== 32'h0005_CDAB) begin
            $display("FAIL: line beat %0d answered %08x, want the dword repeated x4",
                     beats, cpu_dout);
            errors = errors + 1;
          end
        end
        if (seen_ready && beats == 4) g = 40;
        if (g == 0) cpu_valid = 0;
      end
      if (!seen_ready || beats != 4) begin
        $display("FAIL: line read delivered ready=%b beats=%0d", seen_ready, beats);
        errors = errors + 1;
      end
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_PEGC: PASS");
      $finish;
    end else
      $fatal(1, "TB_PC9821_PEGC: FAIL (%0d errors)", errors);
  end

endmodule
