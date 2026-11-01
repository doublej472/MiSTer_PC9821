// ==== WHAT THIS PROVES ====
// TB_PC9821_GVRAM_CONTENTION: a CPU plane-window store completes while the scanout is fetching, because the two clients reach the planes on SEPARATE SDRAM requesters and the store must never wait on the scanout's line fetch -- the ITF's own boot code fills a whole 32 KiB plane with a rep stosd while the display fetches every line.
//
// The old contention was INSIDE pc9821_gvram: one shared client port served by an
// arbiter whose fixed scanout priority could starve the CPU. The design removes the
// sharing: the CPU's D1 accesses go on the memory_subsystem's mem_* requester and
// the scanout's line fetch on the controller's fourth, so neither can hold the other
// off. What is left to prove is that the CPU's client accesses still complete
// promptly while the scanout issues a column every 8 clk_sys, which is what this
// bench measures.
//
// The backend model reproduces the real store's shape: one transaction at a time, a
// ready pulse at the accept, a read's data a few cycles later, and a byte-enabled
// write. src/memory/sdram.v states its own timing ("T_RCD + CAS + 2*burst_cnt - 1
// cycles from ACT to last data", sdram.v:7).
//
// The machine sets the requirement: on a real PC-9821 the CPU has the bus, and
// the ITF's boot code (BANK4 file offset 0x007D writes port 0x68, 0x0118 sets
// ES=0xA800, and 0x0128 is `rep stosd` with cx=0x2000 writing 0xFFFFFFFF across
// 32 KiB of the blue plane window) does a full-plane fill while the display
// runs. A fill that cannot finish is a machine that never boots.
module tb_pc9821_gvram_contention;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  localparam [31:0] GVRAM_BASE = 32'h0300_0000;

  // ==== DUT ====
  reg        access_page = 0;
  reg  [1:0] win_plane = 0;
  reg [14:0] win_offset = 0;
  reg [31:0] cpu_din = 0;
  reg  [3:0] cpu_be = 4'hF;
  reg        cpu_line_read = 0;
  reg        cpu_valid = 0, cpu_write = 0;
  wire [31:0]  cpu_dout;
  wire [31:0] cpu_line_word;
  wire         cpu_ready, cpu_resp_valid, cpu_line_word_valid;

  reg        grcg_we = 0;
  reg  [7:0] grcg_addr = 0, grcg_din = 0;

  reg        egc_gate = 0;
  reg [15:0] egc_access = 16'hFFFF, egc_fgbg = 0, egc_ope = 0,
             egc_fg = 0, egc_mask = 16'hFFFF, egc_bg = 0,
             egc_sft = 0, egc_leng = 0;
  reg        egc_shift_we = 0;

  reg        scan_enable = 0, scan_line_tick = 0, scan_page = 0;
  reg [14:0] scan_line_base = 0;
  reg  [6:0] line_rd_addr = 0;
  reg        line_rd_sel = 0;
  wire [31:0] line_data;
  wire        line_sel, line_ready;

  // The GVRAM's two SDRAM requesters. The scanout and the CPU are on SEPARATE requesters now
  //, so contention is the shared store + the model's single-transaction arbiter, which is
  // the round-robin the controller runs.

  pc9821_gvram_dut #(.SYS_CLOCK_HZ(100_000_000)) dut (
      .clk(clk), .reset(reset),
      .access_page(access_page),
      .win_plane(win_plane), .win_offset(win_offset),
      .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_line_read(cpu_line_read),
      .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_dout(cpu_dout), .cpu_line_word(cpu_line_word),
      .cpu_ready(cpu_ready), .cpu_resp_valid(cpu_resp_valid),
      .cpu_line_word_valid(cpu_line_word_valid),
      .grcg_we(grcg_we), .grcg_addr(grcg_addr), .grcg_din(grcg_din),
      .egc_gate(egc_gate), .egc_access(egc_access), .egc_fgbg(egc_fgbg),
      .egc_ope(egc_ope), .egc_fg(egc_fg), .egc_mask(egc_mask),
      .egc_bg(egc_bg), .egc_sft(egc_sft), .egc_leng(egc_leng),
      .egc_shift_we(egc_shift_we),
      .scan_enable(scan_enable), .scan_line_tick(scan_line_tick),
      .scan_page(scan_page), .scan_line_base(scan_line_base),
      .line_rd_addr(line_rd_addr), .line_rd_sel(line_rd_sel),
      .line_data(line_data), .line_sel(line_sel), .line_ready(line_ready));

  // The backend model: a real accept latency, one transaction at a time, shared storage, and a
  // byte-enabled write (so a one-plane store preserves the other lanes).

  // ==== STIMULUS ====
  // The DUT is driven inline in the run block below; the helpers above are its
  // two verbs - issue one CPU dword store, and deliver one scanout line tick.

  // ==== CHECKS ====
  integer errors = 0;
  task automatic fail(input [8*160-1:0] what);
    begin
      $display("FAIL: %0s", what);
      errors = errors + 1;
    end
  endtask

  // Issue one CPU dword store and return how many cycles it took to be accepted.
  // A store needs four client-port accesses (one per enabled byte lane), so under
  // contention the whole store is what must get through, not one access.
  // A store is COMPLETE ON THE ACCEPT: z486's memory.sv completes an external write on
  // `ready` and consumes `resp_valid` only for a read, so no response strobe follows a store
  //. The request is released in the accept cycle, as z486 releases it -- holding it
  // one cycle longer would present a second, identical access.
  localparam integer STORE_LIMIT = 4000;
  integer took;
  reg  [1:0] st_plane = 2'd0;
  reg [14:0] st_off   = 15'd0;
  reg [31:0] st_data  = 32'd0;
  reg  [3:0] st_be    = 4'hF;
  task automatic cpu_store_timed;
    begin
      @(negedge clk);
      win_plane  = st_plane;
      win_offset = st_off;
      cpu_din    = st_data;
      cpu_be     = st_be;
      cpu_write  = 1;
      cpu_valid  = 1;
      took       = 0;
      @(posedge clk);
      #1;
      while (!cpu_ready && took < STORE_LIMIT) begin
        @(posedge clk);
        #1;
        took = took + 1;
      end
      if (!cpu_ready) begin
        $display("  the store at plane %0d offset 0x%04x was NOT accepted after %0d cycles",
                 st_plane, st_off, took);
        fail("a CPU plane-window store was never accepted -- the SDRAM requester starved it");
        @(negedge clk);
        cpu_valid = 0; cpu_write = 0;
        disable cpu_store_timed;
      end
      // The store completed on this accept. Release the request now, in the accept cycle.
      @(negedge clk);
      cpu_valid = 0;
      cpu_write = 0;
      cpu_be    = 4'hF;
      repeat (4) @(posedge clk);
    end
  endtask

  // Deliver one scanout line: the tick starts a fetch of 80 columns, which the
  // fetcher paces at one issue every 8 clk_sys.
  task automatic scan_line(input [14:0] base);
    begin
      @(negedge clk);
      scan_line_base = base;
      scan_line_tick = 1;
      @(negedge clk);
      scan_line_tick = 0;
    end
  endtask

  integer i;

  initial begin
    scan_enable = 0;
    reset = 1;
    repeat (8) @(posedge clk);
    reset = 0;
    repeat (4) @(posedge clk);

    // ---- CONTROL: with the scanout OFF, a store completes promptly. If this
    // fails the bench is measuring the wrong thing, so it runs first.
    st_plane = 2'd0; st_off = 15'h0010; st_data = 32'hA5A5_5A5A; st_be = 4'hF;
    cpu_store_timed;
    if (took > 400)
      fail("CONTROL: a store with the scanout idle took longer than 400 cycles");
    $display("  control: a store with the scanout idle took %0d cycles", took);

    // ---- THE CHECK: with the scanout fetching, the SAME store must still get
    // through. The scanout issues a column every 8 clk_sys and needs 80 of them
    // per line, so it wants the port for 640 cycles of every line; a fair arbiter
    // leaves the CPU most of the rest, and four client accesses fit in a few tens
    // of cycles. A store that cannot be accepted at all is the defect.
    scan_enable = 1;
    scan_line(15'h0000);
    repeat (40) @(posedge clk);          // let the fetch be well under way

    st_plane = 2'd0; st_off = 15'h0020; st_data = 32'h5A5A_A5A5; st_be = 4'hF;
    cpu_store_timed;
    if (took > 1000)
      fail("CONTENTION: a store took over 1000 cycles while the scanout fetched -- the arbiter starves the CPU");
    else
      $display("  contention: a store with the scanout fetching took %0d cycles", took);

    // Run a burst -- the shape the ITF's rep stosd makes -- and require every one
    // to complete. One slow store is the bug; a burst is what the boot does.
    for (i = 0; i < 16; i = i + 1) begin
      st_plane = 2'd0; st_off = 15'h0040 + i[14:0]; st_data = 32'hFFFF_FFFF; st_be = 4'hF;
    cpu_store_timed;
      if (took > 1000) begin
        fail("CONTENTION: a store in a back-to-back burst took over 1000 cycles");
        i = 16;
      end
    end
    $display("  burst: 16 back-to-back stores issued under contention");

    // A line tick mid-burst must not lose the guest either.
    scan_line(15'h0080);
    st_plane = 2'd1; st_off = 15'h0030; st_data = 32'h1234_5678; st_be = 4'hF;
    cpu_store_timed;
    if (took > 1000)
      fail("CONTENTION: a store issued across a line tick took over 1000 cycles");

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_GVRAM_CONTENTION: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_GVRAM_CONTENTION: FAIL (%0d errors)", errors);
    end
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_GVRAM_CONTENTION: TIMEOUT");
  end

endmodule
