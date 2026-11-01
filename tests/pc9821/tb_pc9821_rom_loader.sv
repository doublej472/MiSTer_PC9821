`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ROM_LOADER:
// The ROM loader: it holds the first word, accepts the write sequence, and signals completion; its registered cpu_run equals rom_ready && !load_error in every cycle.


module tb_pc9821_rom_loader;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;
  reg [31:0] pack_base = 32'h01F8_0000;
  // The top-window shadow store's base (pc9821_memory_subsystem computes
  // pack_base + PACK_BYTES + 0x58000, above the GVRAM/PCM/EMS block). The loader tees the
  // pack's BIOS-top bank into it, so a word staged in [0x20000, 0x28000) is written a
  // SECOND time here.
  reg [31:0] shadow_base = 32'h0209_0000;
  reg ioctl_download = 0, ioctl_wr = 0;
  reg [15:0] ioctl_index = 0;
  reg [26:0] ioctl_addr = 0;
  reg [15:0] ioctl_dout = 0;
  wire ioctl_wait;
  wire mem_valid;
  reg mem_ready = 0;
  wire [31:0] mem_addr, mem_din;
  wire [3:0] mem_be;
  wire [7:0] mem_burstcount;
  wire mem_write, rom_ready, load_error, saw_download, cpu_run;

  // ==== DUT ====
  pc9821_rom_loader dut (.*);

  integer errors = 0;

  // The registered gate (docs/timing.md, the download gate): cpu_run is the loader's own register
  // and must equal rom_ready && !load_error in EVERY cycle, the downloads and resets included.
  integer run_mismatch = 0;
  always @(posedge clk) begin
    if (cpu_run !== (rom_ready && !load_error)) run_mismatch = run_mismatch + 1;
  end
  integer accepted = 0;
  reg [31:0] got_addr[0:7];
  reg [31:0] got_data[0:7];
  reg [3:0] got_be[0:7];

  always @(posedge clk) begin
    if (mem_valid && mem_ready) begin
      got_addr[accepted] = mem_addr;
      got_data[accepted] = mem_din;
      got_be[accepted] = mem_be;
      accepted = accepted + 1;
    end
  end

  // The shadow tee. Counted separately because it is a second write of a word
  // the loader has already staged, addressed in the shadow store rather than the pack.
  integer    tee_writes = 0;
  reg [31:0] last_tee_addr;
  reg [31:0] last_tee_data;
  always @(posedge clk) begin
    if (mem_valid && mem_ready &&
        (mem_addr >= shadow_base) && (mem_addr < (shadow_base + 32'h0000_8000))) begin
      tee_writes   = tee_writes + 1;
      last_tee_addr = mem_addr;
      last_tee_data = mem_din;
    end
  end

  // THE TWO-REQUEST CONTRACT, measured: the pack write and the shadow write are separate
  // requests with mem_valid LOW for a cycle between them, and ioctl_wait does not release
  // between them, so no ioctl word is dropped while the tee is owed.
  reg     tee_watch = 0, tee_saw_low = 0, tee_wait_dropped = 0;
  integer tee_order_violations = 0;
  wire pack_top  = (mem_addr >= (pack_base + 32'h0002_0000)) &&
                   (mem_addr <  (pack_base + 32'h0002_8000));
  wire shadow_wr = (mem_addr >= shadow_base) && (mem_addr < (shadow_base + 32'h0000_8000));
  always @(posedge clk) begin
    if (mem_valid && mem_ready && pack_top) begin
      tee_watch        <= 1'b1;
      tee_saw_low      <= 1'b0;
      tee_wait_dropped <= 1'b0;
    end else if (tee_watch) begin
      if (!mem_valid)  tee_saw_low      <= 1'b1;
      if (!ioctl_wait) tee_wait_dropped <= 1'b1;
      if (mem_valid && mem_ready && shadow_wr) begin
        tee_watch <= 1'b0;
        if (!tee_saw_low || tee_wait_dropped)
          tee_order_violations <= tee_order_violations + 1;
      end
    end
  end
  // ==== STIMULUS ====

  task automatic send_word(input [26:0] addr, input [15:0] data);
    begin
      while (ioctl_wait) @(negedge clk);
      @(negedge clk);
      ioctl_addr = addr;
      ioctl_dout = data;
      ioctl_wr = 1;
      @(negedge clk);
      ioctl_wr = 0;
    end
  endtask
  // ==== CHECKS ====

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    reset = 0;
    ioctl_download = 1;

    // Capture while backend is stalled; second word must see wait until the
    // first buffered write is accepted.
    send_word(27'h0000000, 16'h1234);
    #1;
    if (!ioctl_wait || !mem_valid) begin
      $display("FAIL loader did not hold first word");
      errors = errors + 1;
    end
    fork
      begin
        send_word(27'h0000002, 16'hABCD);
      end
      begin
        repeat (3) @(negedge clk);
        mem_ready = 1;
      end
    join
    repeat (3) @(posedge clk);

    // Upper half of the next DWORD exercises byte enables and data placement.
    send_word(27'h0000006, 16'h5678);
    repeat (2) @(posedge clk);
    ioctl_download = 0;
    repeat (3) @(posedge clk);

    if (accepted != 3 ||
        got_addr[0] !== 32'h01F80000 || got_data[0] !== 32'h00001234 || got_be[0] !== 4'b0011 ||
        got_addr[1] !== 32'h01F80000 || got_data[1] !== 32'hABCD0000 || got_be[1] !== 4'b1100 ||
        got_addr[2] !== 32'h01F80004 || got_data[2] !== 32'h56780000 || got_be[2] !== 4'b1100) begin
      $display("FAIL write sequence accepted=%0d", accepted);
      errors = errors + 1;
    end
    if (!rom_ready || load_error || !saw_download ||
        mem_burstcount != 8'd1 || !mem_write) begin
      $display("FAIL successful completion state ready=%b error=%b", rom_ready, load_error);
      errors = errors + 1;
    end

    // A core (OSD) reset must preserve the loaded pack: SDRAM survives the
    // reset, so rom_ready holds without another download.
    repeat (2) @(posedge clk);
    reset = 1;
    repeat (2) @(posedge clk);
    reset = 0;
    repeat (4) @(posedge clk);
    if (!rom_ready || load_error) begin
      $display("FAIL core reset lost loaded pack ready=%b err=%b",
               rom_ready, load_error);
      errors = errors + 1;
    end

    // A later RAM-size change re-bases the reserve; the next download lands
    // at the new pack base and re-registers the pack there.
    pack_base = 32'h0100_0000;
    ioctl_download = 1;
    send_word(27'h0000000, 16'h4321);
    ioctl_download = 0;
    repeat (4) @(posedge clk);
    if (!rom_ready || load_error) begin
      $display("FAIL re-download at new pack base ready=%b err=%b",
               rom_ready, load_error);
      errors = errors + 1;
    end
    if (got_addr[3] !== 32'h0100_0000 || got_data[3] !== 32'h0000_4321) begin
      $display("FAIL re-download address %08x data %08x",
               got_addr[3], got_data[3]);
      errors = errors + 1;
    end

    // A new malformed download clears ready and fails closed. No backend write.
    // The second address is the first one past the 1 MiB reserve: it used to be the
    // reserve's own end (0x80000) and is now inside it, so this is where the
    // reserve size and this bench must agree.
    ioctl_download = 1;
    @(negedge clk);
    send_word(27'h0000001, 16'hDEAD); // unaligned
    send_word(27'h0100000, 16'hBEEF); // outside the 1 MiB reserve
    ioctl_download = 0;
    repeat (3) @(posedge clk);
    if (!load_error || rom_ready || accepted != 4) begin
      $display("FAIL malformed pack containment ready=%b error=%b accepted=%0d",
               rom_ready, load_error, accepted);
      errors = errors + 1;
    end

    // THE SHADOW TEE: a word staged in the BIOS-top bank (pack 0x20000-0x27FFF) must be
    // written a SECOND time, inside the shadow store, or an offset the firmware never
    // stores reads SDRAM residue instead of ROM through the shadow layer. Every word
    // this bench staged before now was outside that bank, so this is the first tee.
    ioctl_download = 1;
    @(negedge clk);
    send_word(27'h000_2_0E90, 16'h5A5A);
    // Hold the download until the loader's WHOLE sequence is accepted: ioctl_wait is the
    // release, and it must not drop between the pack write and the shadow write.
    while (ioctl_wait) @(negedge clk);
    ioctl_download = 0;
    repeat (4) @(posedge clk);
    if (tee_writes != 1 || last_tee_addr !== (shadow_base + 32'h0000_0E90) ||
        last_tee_data !== 32'h0000_5A5A) begin
      $display("FAIL shadow tee count=%0d addr=%08x data=%08x, want 1/%08x/00005A5A",
               tee_writes, last_tee_addr, last_tee_data, shadow_base + 32'h0000_0E90);
      errors = errors + 1;
    end else begin
      $display("SHADOW TEE pack[0x20E90]=5A5A also written at shadow[0x0E90]");
    end
    if (tee_order_violations != 0) begin
      $display("FAIL tee is not two separate requests: mem_valid not low between them, or ioctl_wait released early (%0d violations)",
               tee_order_violations);
      errors = errors + 1;
    end else begin
      $display("TWO REQUESTS mem_valid dropped between the pack and shadow writes; ioctl_wait held until both were accepted");
    end

    // Other ioctl indices are ignored and must not stall unrelated downloads.
    ioctl_index = 16'd1;
    ioctl_download = 1;
    ioctl_wr = 1;
    ioctl_addr = 0;
    @(posedge clk);
    #1;
    if (ioctl_wait || mem_valid) begin
      $display("FAIL unrelated ioctl index was consumed or stalled");
      errors = errors + 1;
    end

    // A download that ends early: the loader does not check how much arrived, so a
    // truncated pack reports ready and the guest boots whatever the SDRAM holds at the
    // reset vector. Reported, not asserted -- enforcing it needs a size the bench cannot
    // supply at unit scale (it drives a handful of words), and the benches and the real
    // pack download different amounts by design. This is the limitation, measured: if the
    // numbers below ever change, the loader changed.
    ioctl_index = 16'd0;
    ioctl_download = 1;
    @(negedge clk);
    for (integer t = 0; t < 64; t = t + 1)
      send_word(t * 2, 16'h1234);
    ioctl_download = 0;
    repeat (4) @(posedge clk);
    $display("ROM LOADER short download: ready=%b error=%b (no size check exists)",
             rom_ready, load_error);
    if (run_mismatch != 0) begin
      $display("FAIL cpu_run differed from rom_ready && !load_error in %0d cycles", run_mismatch);
      errors = errors + 1;
    end
  // ==== VERDICT ====

    if (errors == 0) begin
        $display("TB_PC9821_ROM_LOADER: PASS");
        $finish;
    end
    else $fatal(1, "TB_PC9821_ROM_LOADER: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog. The runner also bounds wall time
  // (BENCH_TIMEOUT) and greps the PASS marker, but a bench that
  // blocks on a DUT signal with no bound would hang CI forever.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_ROM_LOADER: TIMEOUT");
  end

endmodule
