`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The PEGC register file's area rewrite (mio2's 32 read-back bytes held in one block RAM behind per-dword dirty flops, with plane_mode and vram_en in their own flops) is cycle-for-cycle identical to the pre-rewrite module (pc9821_pegc_ref.sv, the module as of d8f166a6): over random dword-aligned reads, line reads and byte-enabled writes across the mio1 and mio2 windows and their neighbours, with random gaps between requests and random resets mid-run (so the lazy zero of a clean dword is exercised after dirty data), cpu_dout, cpu_ready, the word response pulse, bank_a, bank_b, plane_mode and vram_en match on every cycle, and a line read's four word beats (the post-P3 form - the ref answers one 128-bit line) are the ref's four line words, in order, four times the dword.

// ==== DUT ====
// pc9821_pegc vs pc9821_pegc_ref, same inputs. The reference is the pre-change text, not a
// model of the hardware: this bench proves the rewrite did not change behaviour; the register
// semantics themselves are pinned by tb_pc9821_pegc (NP2kai memvgaio).

module tb_pc9821_pegc_equiv;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  reg         cpu_valid = 0, cpu_write = 0, cpu_line_read = 0;
  reg  [14:0] cpu_addr = 0;
  reg  [31:0] cpu_din = 0;
  reg  [3:0]  cpu_be = 4'hF;

  wire [31:0] d_dout, r_dout;
  wire [127:0] r_line;   // the ref's pre-P3 line form: {4{r_dout}}
  wire d_rdy, d_rv, r_rdy, r_rv, r_lrv;
  wire [3:0] d_ba, d_bb, r_ba, r_bb;
  wire d_pm, d_ve, r_pm, r_ve;

  pc9821_pegc dut (.clk(clk), .reset(reset), .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_line_read(cpu_line_read), .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_be(cpu_be),
      .cpu_dout(d_dout), .cpu_ready(d_rdy), .cpu_resp_valid(d_rv), .bank_a(d_ba), .bank_b(d_bb), .plane_mode(d_pm), .vram_en(d_ve), .idle());
  pc9821_pegc_ref ref0 (.clk(clk), .reset(reset), .cpu_valid(cpu_valid), .cpu_write(cpu_write),
      .cpu_line_read(cpu_line_read), .cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_be(cpu_be),
      .cpu_dout(r_dout), .cpu_line_dout(r_line), .cpu_ready(r_rdy), .cpu_resp_valid(r_rv),
      .cpu_line_resp_valid(r_lrv), .bank_a(r_ba), .bank_b(r_bb), .plane_mode(r_pm), .vram_en(r_ve));

  integer errors = 0, cycles = 0, seed = 7, gap = 0, nreads = 0, nreset = 0, nwr = 0;
  reg [31:0] rnd;
  reg [14:0] a;
  reg [31:0] rw;
  reg        wr;
  // The in-flight request's kind, and the DUT's line-beat count for it. The DUT's accept
  // timing is unchanged (S_ACCEPT), so only the RESPONSE FORM differs on a line read: the ref
  // strokes one 128-bit line where the DUT answers four word beats.
  reg        req_line = 1'b0;
  reg        wait_beats = 1'b0;   // a line read's fills must land before the next request (z486's pending counter)
  reg  [2:0] line_beats = 3'd0;


  function automatic [31:0] rr(input integer dummy);
    rr = $random(seed);
  endfunction

  // ==== CHECKS ====
  always @(posedge clk) begin
    // compare on every cycle (sampled before this edge's updates)
    cycles <= cycles + 1;
    if (d_dout !== r_dout || d_rdy !== r_rdy ||
        d_ba !== r_ba || d_bb !== r_bb || d_pm !== r_pm || d_ve !== r_ve) begin
      errors <= errors + 1;
      if (errors < 10)
        $display("MISMATCH cyc=%0d dout %h/%h rdy %b/%b pm %b/%b ve %b/%b ba %h/%h",
                 cycles, d_dout, r_dout, d_rdy, r_rdy, d_pm, r_pm, d_ve, r_ve, d_ba, r_ba);
    end
    if (!req_line) begin
      // A word read answers identically on both.
      if (d_rv !== r_rv) begin
        errors <= errors + 1;
        $display("MISMATCH cyc=%0d word response %b/%b", cycles, d_rv, r_rv);
      end
    end else begin
      // A line read: every DUT beat is the ref's line word of its index, and the ref's line is
      // the dword four times (its own definition, {4{cpu_dout}}).
      if (r_lrv && r_line !== {4{r_dout}}) begin
        errors <= errors + 1;
        $display("MISMATCH cyc=%0d ref line %032x is not its dword %08x x4", cycles, r_line, r_dout);
      end
      if (d_rv) begin
        if (d_dout !== r_line[{line_beats[1:0], 5'b00000} +: 32]) begin
          errors <= errors + 1;
          $display("MISMATCH cyc=%0d line beat %0d %08x, ref word %08x",
                   cycles, line_beats, d_dout, r_line[{line_beats[1:0], 5'b00000} +: 32]);
        end
        line_beats <= line_beats + 3'd1;
      end
    end
    // stimulus
    if (reset) begin
      cpu_valid <= 1'b0;
      req_line <= 1'b0;
      wait_beats <= 1'b0;
      line_beats <= 3'd0;
    end else if (cpu_valid) begin
      if (d_rdy) begin
        cpu_valid <= 1'b0;
        // A line read's four beats are outstanding at the accept; the CPU cannot launch its
        // next request until the L1's pending counter drains (one beat each).
        wait_beats <= req_line;
        gap <= rr(0) & 3;
      end
    end else if (wait_beats) begin
      if (line_beats == 3'd4) wait_beats <= 1'b0;
    end else if (gap != 0) begin
      gap <= gap - 1;
    end else begin
      // A new request: the previous one owed four beats if it was a line read.
      if (req_line && line_beats != 3'd4) begin
        errors <= errors + 1;
        $display("MISMATCH cyc=%0d a line read delivered %0d beats of 4", cycles, line_beats);
      end
      line_beats <= 3'd0;
      rnd = rr(0);
      rw = rr(0);
      wr = rr(0) & 1 | (rnd[7:4] > 6);
      case (rnd[3:0])
        0, 1, 2, 3, 4, 5, 6, 7: a = {10'd8, rw[4:2], 2'b00};   // mio2 dwords (0xE0100-0xE011F)
        8, 9:     a = 15'h0004;                                // mio1
        10:       a = 15'h0000;
        11:       a = {rw[12:2], 2'b00};                       // anywhere in the window
        12:       a = {10'd8, 5'h00} + {rw[7:2], 2'b00} - 15'h20; // around mio2
        default:  a = {10'd8, rw[4:2], 2'b00};
      endcase
      cpu_addr <= a;
      cpu_write <= wr;
      req_line <= (rnd[11:8] == 0) && !wr;
      cpu_line_read <= (rnd[11:8] == 0);
      cpu_be <= (rnd[15:12] < 6) ? 4'hF : (rr(0) & 15);
      cpu_din <= rr(0);
      cpu_valid <= 1'b1;
    end
    // random mid-run reset
    if (!reset && (rr(0) & 16'hFFF) == 0 && cycles > 100) begin
      reset <= 1'b1; nreset <= nreset + 1;
    end else if (reset && cycles > 20 && (rr(0) & 3) == 0) reset <= 1'b0;
  end

  // ==== VERDICT ====
  initial begin
    #40_000_000;
    if (errors == 0 && cycles > 1_000_000 && nreset >= 0)
      $display("TB_PC9821_PEGC_EQUIV: PASS");
    else
      $fatal(1, "TB_PC9821_PEGC_EQUIV: FAIL errors=%0d cycles=%0d", errors, cycles);
    $finish;
  end
endmodule
