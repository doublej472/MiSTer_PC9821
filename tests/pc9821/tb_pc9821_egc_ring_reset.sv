`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The EGC's M10K ring is scrubbed on reset, so its contents after a reset are the ones a fresh engine has (zero, exactly the register form and the NP2kai reference's rst() give) and not whatever the run before the reset left. A descending byte-unit produce serves the byte its OWN feed just wrote (NP2kai egcsftb_dnn_sub reads outptr[0] before the decrement, mem/memegc.c:174-178), and the bench pins that against a POISONED ring: it fills all 64 ring entries with 0xA5 through ascending word feeds, patches the next read's source byte to 0x5A, arms a descending byte unit and asserts the read serves 0x5A (the fresh feed) and never the 0xA5 survivor - the fail-first regression's within-unit produce-slot fix, where the old slot read one entry BELOW the write pointer and served the survivor. The same shape after a MID-RUN reset serves a third fresh byte 0x5C: no pre-reset ring content may leak from any slot; the scrub keeps the never-fed entries at the register form zero for parity with the reference's rst().
//
// The EGC's M10K ring is scrubbed on reset, so its contents after a reset are the ones a
// fresh engine has (zero, exactly the register form and the NP2kai reference's rst() give)
// and not whatever the run before the reset left.
//
// ---- the bench's own account of where the expectation comes from ----
//
// A descending byte-unit produce serves the byte its OWN feed just wrote: NP2kai's
// egcsftb_dnn_sub reads outptr[0] BEFORE the decrement (mem/memegc.c:145-179, especially
// :174-178), and the feed at inptr == outptr just wrote that entry. The pre-fix RTL took
// the word unit's SECOND-step slot (`outptr_feed + mv1`) for byte units too, reading the
// ring entry one BELOW the write pointer -- the within-unit bug, corrected
// by the produce-slot fix in pc9821_egc.sv (and transcribed in
// tests/pc9821/pc9821_egc_ref.sv's sftb_*_sub order). The first account of
// this bench was written against that old slot and expected the SURVIVOR read; against
// NP2kai's own order (and the golden reference, which returns the fed byte) that
// expectation was the bug, so the checks below pin the corrected semantics instead:
//   [source: NP2kai mem/memegc.c:174-178 for the read slot]
//
// WHAT IS ASSERTED:
//   1. with the ring POISONED with 0xA5 all around it and the read's source byte patched
//      to 0x5A, a descending byte access BEFORE any reset serves 0x5A
//      (the fresh feed) - NOT the 0xA5 survivor. The old produce slot served 0xA5 here,
//      so this is the fail-first regression for the within-unit fix;
//   2. after a MID-RUN reset the SAME access with a third fresh byte (0x5C) serves 0x5C:
//      neither the 0xA5 poison nor check 1's 0x5A may leak from any ring slot. Under the
//      corrected slot no reachable produce reads a never-fed entry (NP2kai's own stack
//      gate arms the feed trail first), so the scrub's zeroed never-fed entries are
//      register-form / reference rst() parity and future-proofing (the earlier finding stays
//      retired) rather than a CPU-visible difference; the scrub stays.

`default_nettype none

module tb_pc9821_egc_ring_reset;
  `timescale 1ns/1ps
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // ---- DUT register file (latched by pc9821_iobus in the machine) ----
  reg [15:0] reg_access = 16'hFFF0;
  reg [15:0] reg_fgbg   = 16'h00FF;
  reg [15:0] reg_ope    = 16'h0000;
  reg [15:0] reg_fg     = 16'h0000;
  reg [15:0] reg_mask   = 16'hFFFF;
  reg [15:0] reg_bg     = 16'h0000;
  reg [15:0] reg_sft    = 16'h0000;
  reg [15:0] reg_leng   = 16'h000F;
  reg        reg_shift_we = 1'b0;

  // ---- CPU access ----
  reg         cpu_page = 1'b0;
  reg [14:0]  cpu_offset = 15'd0;
  reg [1:0]   cpu_plane = 2'd0;
  reg [31:0]  cpu_din = 32'd0;
  reg [3:0]   cpu_be = 4'hF;
  reg         cpu_valid = 1'b0, cpu_write = 1'b0;
  wire [31:0] cpu_dout;
  wire        cpu_ready, cpu_resp_valid;

  // ---- D1 client ----
  wire        cl_valid, cl_write, cl_burst;
  wire [15:0] cl_addr;
  wire [31:0] cl_wdata;
  wire [3:0]  cl_wbe;
  wire [63:0] cl_wdata2;
  reg  [31:0] cl_rdata;
  reg         cl_done;
  reg         cl_ready;

  // ==== DUT ====
  pc9821_egc dut (
      .clk(clk), .reset(reset),
      .reg_access(reg_access), .reg_fgbg(reg_fgbg), .reg_ope(reg_ope),
      .reg_fg(reg_fg), .reg_mask(reg_mask), .reg_bg(reg_bg),
      .reg_sft(reg_sft), .reg_leng(reg_leng), .reg_shift_we(reg_shift_we),
      .cpu_page(cpu_page), .cpu_offset(cpu_offset), .cpu_plane(cpu_plane),
      .cpu_din(cpu_din), .cpu_be(cpu_be), .cpu_valid(cpu_valid),
      .cpu_write(cpu_write), .cpu_dout(cpu_dout), .cpu_ready(cpu_ready),
      .cpu_resp_valid(cpu_resp_valid),
      .cl_valid(cl_valid), .cl_ready(cl_ready), .cl_write(cl_write),
      .cl_addr(cl_addr), .cl_wdata(cl_wdata), .cl_wbe(cl_wbe),
      .cl_burst(cl_burst), .cl_wdata2(cl_wdata2),
      .cl_rdata(cl_rdata), .cl_done(cl_done)
  );

  // ==== BEHAVIOURAL GVRAM BACKEND (the D1 client) ====
  // One plane byte per lane per access, addressed by cl_addr = {page, plane byte offset}
  // (pc9821_gvram.sv's D1 contract). Flat array: index plane*32768 + offset.
  localparam integer PLANE_LEN = 32768;
  reg [7:0] pmem [0:4*PLANE_LEN-1];

  reg [14:0] rd_off;
  reg [1:0]  rd_last;
  reg        rd_busy;
  reg [31:0] rd_word;
  reg        cl_done_r;
  reg        wr_pending;

  assign cl_ready = !rd_busy;
  assign cl_done  = cl_done_r;
  assign cl_rdata = rd_word;

  function [1:0] last_col(input [3:0] be);
    integer i;
    begin
      last_col = 2'd0;
      for (i = 0; i < 4; i = i + 1) if (be[i]) last_col = i[1:0];
    end
  endfunction

  always @(posedge clk) begin
    cl_done_r <= 1'b0;
    if (reset) begin
      rd_busy <= 1'b0; rd_off <= 15'd0; rd_last <= 2'd0; rd_word <= 32'd0;
      wr_pending <= 1'b0;
    end else begin
      if (cl_valid && cl_ready) begin
        if (cl_write) begin
          for (integer q = 0; q < 4; q = q + 1) begin
            if (cl_wbe[q])
              pmem[q*PLANE_LEN + cl_addr[14:0]] <= cl_wdata[{q, 3'b000} +: 8];
            if (cl_burst && cl_wbe[q])
              pmem[q*PLANE_LEN + cl_addr[14:0] + 1] <= cl_wdata2[32 + {q, 3'b000} +: 8];
          end
          wr_pending <= !cl_burst;
        end else begin
          rd_off  <= cl_addr[14:0];
          rd_last <= last_col(cl_wbe);
          rd_busy <= 1'b1;
        end
      end else if (rd_busy) begin
        rd_word  <= {pmem[3*PLANE_LEN + rd_off], pmem[2*PLANE_LEN + rd_off],
                     pmem[1*PLANE_LEN + rd_off], pmem[0*PLANE_LEN + rd_off]};
        cl_done_r <= 1'b1;
        if (rd_off[1:0] == rd_last) rd_busy <= 1'b0;
        else rd_off <= rd_off + 1'b1;
      end
      if (wr_pending) begin
        cl_done_r <= 1'b1;
        wr_pending <= 1'b0;
      end
    end
  end

  // ==== CHECK BOOKKEEPING ====
  integer errors = 0;
  integer i;

  // ==== STIMULUS ====
  task automatic arm(input [15:0] sft, input [15:0] leng);
    begin
      @(negedge clk);
      reg_sft = sft; reg_leng = leng; reg_shift_we = 1'b1;
      @(negedge clk);
      reg_shift_we = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic cpu_do(input [14:0] off, input [1:0] plane, input [3:0] be,
                        input wr, output [31:0] dout);
    begin
      @(negedge clk);
      cpu_offset = off; cpu_plane = plane; cpu_din = 32'd0; cpu_be = be;
      cpu_write = wr; cpu_valid = 1'b1;
      while (!cpu_ready) @(negedge clk);
      // Released at the ready edge (z486's shape, src/z486/bus_unit.sv:348-350 `ext_valid_r <= 1'b0`),
      // before the pipelined produce's response cycle - held into it, the S_IDLE accept
      // takes the request twice. Read values are unchanged (EGCREAD.CSV / the machine vectors).
      // The negedge below is the old release's own wait, kept so the +1 stays in the cadence.
      cpu_valid = 1'b0; cpu_write = 1'b0; cpu_be = 4'h0;
      if (!wr) begin
        while (!cpu_resp_valid) @(negedge clk);
        #1; dout = cpu_dout;
      end
      @(negedge clk);
      while (dut.state != pc9821_egc_pkg::EGC_IDLE) @(negedge clk);
      repeat (4) @(posedge clk);
    end
  endtask

  reg [31:0] dout;

  // ==== CHECKS ====

  initial begin : run
    // The client's own read data (the D1 backend) is 0xA5 everywhere: an ascending word
    // feed writes the fetched quad into the ring, so this is what the fill leaves behind.
    for (i = 0; i < 4*PLANE_LEN; i = i + 1) pmem[i] = 8'hA5;

    // Clean start.
    reset = 1'b1;
    reg_shift_we = 1'b0;
    repeat (4) @(posedge clk);
    reset = 1'b0;
    repeat (4) @(posedge clk);

    // fill_ring(0xA5): arm ascending at bit length 0x0FFF and run 16 dword reads. Each dword
    // is two word units, each word unit one produce, each word feed writes TWO ring entries
    // (fd_lo, fd_hi) -> 32 * 2 = all 64 entries.
    arm(16'h0000, 16'h0FFF);
    for (i = 0; i < 16; i = i + 1) cpu_do(15'd0, 2'd0, 4'hF, 1'b0, dout);

    // CONTROL (check 1): patch the read's SOURCE byte to 0x5A while the ring around it is
    // poisoned with the fill's 0xA5, then run the descending byte access. NP2kai's
    // egcsftb_dnn_sub serves the byte the access's OWN feed just wrote (outptr[0] before
    // the decrement, mem/memegc.c:174-178), so the read must return 0x5A - not the 0xA5
    // survivor the fill left in the ring (the old one-off produce slot served it).
    pmem[0] = 8'h5A;
    arm(16'h1000, 16'h0FFF);
    cpu_do(15'd0, 2'd0, 4'b0001, 1'b0, dout);
    $display("RING_RESET control (pre-reset descending byte): dout=0x%08x", dout);
    if (dout[7:0] !== 8'h5A) begin
      $display("FAIL: the descending byte did not serve its own fresh feed: pre-reset byte = 0x%02x, expected 0x5A (a ring survivor leaked)",
               dout[7:0]);
      errors = errors + 1;
    end

    // MID-RUN reset: three cycles, then run.
    reset = 1'b1;
    repeat (3) @(posedge clk);
    reset = 1'b0;
    repeat (4) @(posedge clk);

    // The SAME descending byte access with a THIRD fresh source byte (0x5C). After a reset
    // it must serve 0x5C: neither the 0xA5 poison fill nor check 1's 0x5A may leak from any
    // ring slot, fed or never-fed (the scrub holds the never-fed entries at the register
    // form's zero for parity with the reference's rst()).
    pmem[0] = 8'h5C;
    arm(16'h1000, 16'h0FFF);
    cpu_do(15'd0, 2'd0, 4'b0001, 1'b0, dout);
    $display("RING_RESET post-reset descending byte: dout=0x%08x", dout);
    if (dout[7:0] !== 8'h5C) begin
      $display("FAIL: the descending byte access served 0x%02x after a reset, not the fresh 0x5C: pre-reset ring content leaked",
               dout[7:0]);
      errors = errors + 1;
    end

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_EGC_RING_RESET: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_EGC_RING_RESET: FAIL (%0d errors)", errors);
  end

  initial begin : watchdog
    #2_000_000;
    $fatal(1, "TB_PC9821_EGC_RING_RESET: watchdog fired");
  end

endmodule

`default_nettype wire
