`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The TRAM bridge: byte-enable writes land in the right lanes and a DWORD read returns the response in the expected cycle. The attribute half (0xA2000-0xA3FFF) is pinned to the machine: odd attribute bytes take NO store (NP2kai mem/memtram.c:82-99/130-161 gate on `!(address & 1)`) and read back as 0xFF whatever the plane holds (the Xe10 read-back row (`A2000` | `00 FF 55 AA` | `00 FF 55 FF`), the row behind both paths), on the DWORD read path and on the cache-line fill; the code half odd bytes still take. The store half is checked against a store-port control, never against the bench array. FAIL-FIRST: the pre-fix bridge returns the plane bytes, 83558100 instead of FF55FF00.
//
// This drives the TRAM ARM (route_cg = 0) of pc9821_window_responder, the one engine the TRAM bridge and the CG byte window are now. The TRAM arm is that module's whole behaviour here, and the CG arm is covered by tb_pc9821_cg_window through the memory subsystem; the cycle-by-cycle equivalence of the merged engine against both originals was proven separately when they were merged.
//
// The TRAM bridge: byte-enable writes land in the right lanes and a DWORD read returns the response in the expected cycle. The attribute half (0xA2000-0xA3FFF) is EVEN-ONLY and an odd attribute byte reads back as the machine's 0xFF (the Xe10 read-back row (`A2000` | `00 FF 55 AA` | `00 FF 55 FF`)): odd lanes take no store, and both the DWORD and the cache-line read paths supply 0xFF there, so the read-back is the capture's `00 FF 55 FF` and never the plane's stale byte. FAIL-FIRST: the pre-fix bridge returns the stale bytes.


module tb_pc9821_tram_bridge;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;
  reg [13:0] cpu_addr = 0;
  reg [31:0] cpu_din = 0;
  reg [3:0] cpu_be = 0;
  reg cpu_line_read = 0, cpu_valid = 0, cpu_write = 0;
  wire [31:0] cpu_dout;
  wire [31:0] cpu_line_word;
  wire cpu_ready, cpu_resp_valid, cpu_line_word_valid;
  wire [13:0] tram_addr;
  wire [7:0] tram_din;
  wire tram_we;
  reg [7:0] tram_dout;
  reg [7:0] ram [0:16383];

  // The merged responder's other route and its CG byte port: route_cg = 0 drives the TRAM
  // arm, and the byte port is idle there (the module never strokes byte_rd/byte_we on this
  // route), so byte_dout/byte_hold are the trivially-quiet inputs.
  reg         route_cg = 0;
  wire [4:0]  byte_sel;
  wire        byte_rd;
  reg  [7:0]  byte_dout = 8'h00;
  reg         byte_hold = 0;
  wire [7:0]  byte_din;
  wire        byte_we;

  // The DMA byte port, idle here (tb_pc9821_dma_tram drives it through the memory subsystem).
  reg         dma_valid = 0, dma_write = 0, dma_route_cg = 0;
  reg  [13:0] dma_addr = 14'd0;
  reg   [7:0] dma_din = 8'h00;
  wire        dma_ready, dma_resp_valid;
  wire  [7:0] dma_dout;

  // ==== DUT ====
  pc9821_window_responder dut (.*);

  integer i, errors = 0;

  // A same-cycle ready+resp_valid answer wedges z486, and the phase checks below poll
  // for the response -- they pass with it.
  always @(posedge clk)
    if (cpu_ready && (cpu_resp_valid || cpu_line_word_valid))
      $fatal(1, "ready and response in the same cycle");

  always @(posedge clk) begin
    if (tram_we) begin
      ram[tram_addr] <= tram_din;
      tram_dout <= tram_din;
    end else tram_dout <= ram[tram_addr];
  end
  // ==== STIMULUS ====

  // The four word beats of the last line read, assembled as the L1 does (beat N = line word N).
  reg [127:0] line_cap = 128'd0;

  task automatic start_request(
      input [13:0] addr, input [31:0] data, input [3:0] be,
      input wr, input line);
    integer n;
    begin
      @(negedge clk);
      cpu_addr = addr;
      cpu_din = data;
      cpu_be = be;
      cpu_write = wr;
      cpu_line_read = line;
      cpu_valid = 1;
      while (!cpu_ready) @(negedge clk);
      // Reads deliver data with the response, one cycle after the accept
      // (z486 samples din on resp_valid, matching the open-bus responder). A LINE read is
      // accepted at the walk's start (P3) and its four word beats stream through the walk, so
      // they are gathered here one at a time.
      if (!wr) begin
        if (line) begin
          n = 0;
          line_cap = 128'd0;
          while (n < 4) begin
            @(negedge clk);
            if (cpu_line_word_valid) begin
              line_cap[{n[1:0], 5'b00000} +: 32] = cpu_line_word;
              n = n + 1;
            end
          end
        end else while (!cpu_resp_valid) @(negedge clk);
      end
      #1;
    end
  endtask

  task automatic end_request;
    begin
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_line_read = 0;
      cpu_be = 0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask
  // ==== CHECKS ====

  initial begin
    for (i = 0; i < 16384; i = i + 1) ram[i] = 8'h80 + i[7:0];
    tram_dout = 0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;

    // Address is DWORD-aligned and inactive lanes remain untouched.
    start_request(14'h0123, 32'h44332211, 4'b1011, 1'b1, 1'b0);
    if (cpu_resp_valid || cpu_line_word_valid || ram[14'h0120] !== 8'h11 ||
        ram[14'h0121] !== 8'h22 || ram[14'h0122] !== 8'hA2 ||
        ram[14'h0123] !== 8'h44) begin
      $display("FAIL byte-enable write %02x %02x %02x %02x",
               ram[14'h120], ram[14'h121], ram[14'h122], ram[14'h123]);
      errors = errors + 1;
    end
    end_request();

    start_request(14'h0121, 32'd0, 4'hF, 1'b0, 1'b0);
    if (!cpu_resp_valid || cpu_line_word_valid ||
        cpu_dout !== 32'h44A22211) begin
      $display("FAIL DWORD read %08x resp=%b", cpu_dout, cpu_resp_valid);
      errors = errors + 1;
    end
    end_request();

    // Cache fills are aligned to the 16-byte z486 line and little-endian.
    start_request(14'h0037, 32'd0, 4'hF, 1'b0, 1'b1);
    if (line_cap !== 128'hBFBEBDBCBBBAB9B8B7B6B5B4B3B2B1B0) begin
      $display("FAIL line read %032x", line_cap);
      errors = errors + 1;
    end
    end_request();

    // The attribute half (0xA2000-0xA3FFF) is EVEN-ONLY, and an odd byte reads back as the
    // machine's 0xFF. THE MACHINE'S OWN ROW, not this bench's array: the VRAM probe wrote
    // `00 FF 55 AA` at A2000 and read back `00 FF 55 FF`
    // (the Xe10 read-back row (`A2000` | `00 FF 55 AA` | `00 FF 55 FF`); raw
    // docs/probes/VRAM.TXT:134-136), which is what NP2kai-only would miss - its
    // memtram_rd8 returns the stale memory byte, modelling the store half alone. So: odd
    // attribute bytes take NO store (NP2kai mem/memtram.c:82-99/130-161 gate on
    // `!(address & 1)`), and a CPU read-back of one supplies 0xFF whatever the plane holds.
    // The code half's odd bytes DO take (the first case above writes 0x0121).
    // The two `ram[]` checks below are the STORE-PORT control -- the DUT must not have written
    // the odd lanes -- so they compare against this bench's own power-up fill (ram[i] = 80+i,
    // hence 81/83 at 0x2001/0x2003). The READ-BACK expectations are the machine's capture and
    // never the fill. FAIL-FIRST: the pre-fix bridge returns the stale bytes, 83558100 below,
    // where the machine reads FF55FF00.
    start_request(14'h2000, 32'h44332211, 4'b1111, 1'b1, 1'b0);
    end_request();
    if (ram[14'h2000] !== 8'h11 || ram[14'h2001] !== 8'h81 ||
        ram[14'h2002] !== 8'h33 || ram[14'h2003] !== 8'h83) begin
      $display("FAIL attr-half odd store %02x %02x %02x %02x",
               ram[14'h2000], ram[14'h2001], ram[14'h2002], ram[14'h2003]);
      errors = errors + 1;
    end
    // The capture's own byte pattern as a DWORD ({AA,55,FF,00} = the probe's `00 FF 55 AA`).
    start_request(14'h2000, 32'hAA55FF00, 4'b1111, 1'b1, 1'b0);
    end_request();
    if (ram[14'h2000] !== 8'h00 || ram[14'h2001] !== 8'h81 ||
        ram[14'h2002] !== 8'h55 || ram[14'h2003] !== 8'h83) begin
      $display("FAIL attr-half second store %02x %02x %02x %02x",
               ram[14'h2000], ram[14'h2001], ram[14'h2002], ram[14'h2003]);
      errors = errors + 1;
    end
    // Bytes at 0x2000..0x2003 = 00 FF 55 FF, the machine's read-back.
    start_request(14'h2000, 32'd0, 4'hF, 1'b0, 1'b0);
    if (!cpu_resp_valid || cpu_dout !== 32'hFF55FF00) begin
      $display("FAIL attr-half readback %08x resp=%b", cpu_dout, cpu_resp_valid);
      errors = errors + 1;
    end
    end_request();
    // A cache fill of the attribute plane substitutes every odd lane the same way (the word
    // beats are the responder's own read_data words). Lanes 4..15 still hold the fill, so this
    // pins the substitution per lane and not just in the final byte.
    start_request(14'h2000, 32'd0, 4'hF, 1'b0, 1'b1);
    if (line_cap !== 128'hFF8E_FF8C_FF8A_FF88_FF86_FF84_FF55_FF00) begin
      $display("FAIL attr-half line read %032x", line_cap);
      errors = errors + 1;
    end
    end_request();
  // ==== VERDICT ====

    if (errors == 0) begin
        $display("TB_PC9821_TRAM_BRIDGE: PASS");
        $finish;
    end
    else $fatal(1, "TB_PC9821_TRAM_BRIDGE: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog. The runner also bounds wall time
  // (BENCH_TIMEOUT) and greps the PASS marker, but a bench that
  // blocks on a DUT signal with no bound would hang CI forever.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_TRAM_BRIDGE: TIMEOUT");
  end

endmodule
