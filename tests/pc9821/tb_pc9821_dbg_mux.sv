`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DBG_MUX: The debug-UART mux (pc9821_dbg_mux) puts three record sources onto one byte stream without ever interleaving two records: every output record is one source's next record, byte for byte, in that source's order, whatever the mix of CD-log, display-log and CPU-instrument record types (including payload bytes equal to the 0xA5 sync), with sources that pause between bytes and an output that stalls at random; with all sources always ready the grant rotates round-robin (no source starves); and a stray non-sync byte passes through as a record of its own without taking the grant.
//
// The bench carries its own record-length table, written from the record definitions (the CD log's
// 4-byte header plus payload; pc9821_gdc_log; pc9821_dbg_cpu), not read from the DUT, and the
// sources are synthetic, so a wrong length in the DUT's table splits a record and fails on a
// POSITION: a mux whose table is one byte short for any of the types fails here.

`default_nettype none

module tb_pc9821_dbg_mux;
  // ==== DUT ====
  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg  [23:0] in_byte;
  reg  [2:0]  in_we;
  wire [2:0]  in_acc;
  wire [7:0]  out_byte;
  wire        out_we;
  reg         out_acc_en = 1'b1;
  wire        out_accept = out_we && out_acc_en;
  pc9821_dbg_mux #(.N(3)) dut (.clk(clk), .in_byte(in_byte), .in_we(in_we), .in_accept(in_acc),
                               .out_byte(out_byte), .out_we(out_we), .out_accept(out_accept));

  // ==== STIMULUS ====
  reg [31:0] lfsr = 32'hC0FFEE11;
  function automatic [31:0] rnd();
    begin
      lfsr = lfsr ^ (lfsr << 13); lfsr = lfsr ^ (lfsr >> 17); lfsr = lfsr ^ (lfsr << 5);
      rnd = lfsr;
    end
  endfunction
  // The bench's own table: total bytes by type (0 = not a record type).
  function automatic integer tlen(input [7:0] t);
    case (t)
      8'h01: tlen = 8;   8'h02: tlen = 16;  8'h03: tlen = 12;  8'h04: tlen = 18;
      8'h05: tlen = 9;   8'h06: tlen = 9;   8'h07: tlen = 5;   8'h08: tlen = 5;
      8'h09: tlen = 5;   8'h0A: tlen = 5;   8'h0B: tlen = 12;
      8'h10, 8'h11, 8'h12, 8'h13, 8'h14, 8'h15, 8'h16, 8'h17, 8'h18: tlen = 7;
      8'h19: tlen = 9;   8'h1E: tlen = 7;   8'h1F: tlen = 7;
      8'h20, 8'h21: tlen = 34;
      8'h30, 8'h31: tlen = 15;  8'h32: tlen = 8;  8'h43: tlen = 15;  8'h44: tlen = 13;
      default: tlen = 0;
    endcase
  endfunction
  // type menus per source
  function automatic [7:0] pick_type(input integer s);
    integer r;
    begin
      r = rnd() % 8;
      case (s)
        0: pick_type = (r < 5) ? 8'(1 + r) : (r == 5 ? 8'h09 : (r == 6 ? 8'h0B : 8'h0A));
        1: pick_type = (r < 6) ? 8'(8'h10 + r) : (r == 6 ? 8'h19 : 8'h1E);
        default: pick_type = (r < 2) ? 8'h20 : (r < 4 ? 8'h30 : (r == 4 ? 8'h32 : (r == 5 ? 8'h43 : (r == 6 ? 8'h44 : 8'h21))));
      endcase
    end
  endfunction

  localparam integer NREC = 150;
  localparam integer MAXB = 5200;
  reg [7:0] sb [0:2][0:MAXB-1];     // source bytes (the records back to back)
  integer   slen [0:2];             // bytes in each
  integer   spos [0:2];             // next byte to present
  integer   nrec_s [0:2];
  integer   rec_at [0:2][0:NREC];   // start offset of each record
  integer   gap_en = 0;             // sources pause between bytes
  integer   always_ready = 0;

  task automatic build_source(input integer s);
    integer r, b, t, l;
    begin
      slen[s] = 0;
      for (r = 0; r < NREC; r = r + 1) begin
        t = pick_type(s); l = tlen(t[7:0]);
        rec_at[s][r] = slen[s];
        sb[s][slen[s]] = 8'hA5; sb[s][slen[s] + 1] = t[7:0];
        for (b = 2; b < l; b = b + 1) sb[s][slen[s] + b] = (rnd() % 5 == 0) ? 8'hA5 : rnd()[7:0];
        slen[s] = slen[s] + l;
      end
      rec_at[s][NREC] = slen[s];
      nrec_s[s] = NREC;
      spos[s] = 0;
    end
  endtask

  // the source drivers: present sb[s][spos[s]] and hold it until accepted
  integer s;
  reg [2:0] hold = 3'b000;
  reg [2:0] took = 3'b000;
  always @(posedge clk) took <= in_we & in_acc;   // sampled at the edge the mux samples them
  always @(negedge clk) begin
    for (s = 0; s < 3; s = s + 1) begin
      if (took[s]) begin                     // taken at the last edge
        spos[s] = spos[s] + 1;
        hold[s] = 1'b0;
      end
      if (spos[s] < slen[s] && (hold[s] || always_ready != 0 || gap_en == 0 || rnd() % 3 != 0)) begin
        in_we[s] = 1'b1; in_byte[8*s +: 8] = sb[s][spos[s]]; hold[s] = 1'b1;
      end else begin
        in_we[s] = 1'b0; in_byte[8*s +: 8] = 8'h00;
      end
    end
  end

  // capture: (byte, granted source) per accepted output byte
  reg [7:0] ob [0:19999];
  integer   osrc [0:19999];
  integer   no = 0;
  always @(posedge clk) if (out_accept) begin
    ob[no] <= out_byte;
    osrc[no] <= in_acc[0] ? 0 : in_acc[1] ? 1 : 2;
    no <= no + 1;
  end

  integer errors = 0;
  task automatic fail(input string m);
    begin if (errors < 20) $display("FAIL: %0s", m); errors = errors + 1; end
  endtask

  // Walk the captured stream: every record whole, from one source, equal to that source's next.
  integer recs_out [0:2];
  integer rotation_viol;
  task automatic check_stream(input integer expect_rotation);
    integer i, src, l, b, nxt;
    integer lastsrc;
    begin
      i = 0; lastsrc = -1; rotation_viol = 0;
      recs_out[0] = 0; recs_out[1] = 0; recs_out[2] = 0;
      while (i < no) begin
        src = osrc[i];
        if (ob[i] !== 8'hA5) begin fail($sformatf("byte %0d: record does not start with A5 (%02x)", i, ob[i])); i = no; end
        else begin
          l = tlen(ob[i+1]);
          if (l == 0 || i + l > no) begin fail($sformatf("byte %0d: unknown/short record type %02x", i, ob[i+1])); i = no; end
          else begin
            nxt = recs_out[src];
            for (b = 0; b < l; b = b + 1) begin
              if (osrc[i+b] != src) fail($sformatf("record at %0d: byte %0d came from source %0d, not %0d", i, b, osrc[i+b], src));
              if (nxt >= NREC || ob[i+b] !== sb[src][rec_at[src][nxt] + b])
                fail($sformatf("record at %0d (source %0d #%0d): byte %0d is %02x", i, src, nxt, b, ob[i+b]));
            end
            if (expect_rotation != 0 && lastsrc >= 0 && src != (lastsrc + 1) % 3 && recs_out[0] < NREC && recs_out[1] < NREC && recs_out[2] < NREC)
              rotation_viol = rotation_viol + 1;
            lastsrc = src;
            recs_out[src] = nxt + 1;
            i = i + l;
          end
        end
      end
    end
  endtask

  // ==== CHECKS ====
  integer n;
  initial begin
    in_we = 3'b000; in_byte = 24'd0;
    repeat (4) @(negedge clk);

    // 1. back to back, output always ready, all sources always ready: strict rotation
    build_source(0); build_source(1); build_source(2);
    no = 0; always_ready = 1; gap_en = 0; out_acc_en = 1'b1;
    repeat (4 * MAXB * 3) @(negedge clk);
    check_stream(1);
    for (n = 0; n < 3; n = n + 1)
      if (recs_out[n] != NREC) fail($sformatf("run 1: source %0d delivered %0d of %0d records", n, recs_out[n], NREC));
    if (rotation_viol != 0) fail($sformatf("run 1: %0d grants broke the round-robin order", rotation_viol));

    // 2. sources that pause between bytes, output stalling at random
    build_source(0); build_source(1); build_source(2);
    no = 0; always_ready = 0; gap_en = 1;
    for (n = 0; n < 40 * MAXB; n = n + 1) begin
      out_acc_en = (rnd() % 3 != 0);
      @(negedge clk);
    end
    out_acc_en = 1'b1;
    repeat (4 * MAXB) @(negedge clk);
    check_stream(0);
    for (n = 0; n < 3; n = n + 1)
      if (recs_out[n] != NREC) fail($sformatf("run 2: source %0d delivered %0d of %0d records", n, recs_out[n], NREC));

    // 3. a stray non-sync byte from one source passes through on its own (it takes no grant) and
    //    the record that follows it is intact
    slen[0] = 1 + tlen(8'h03); slen[1] = 0; slen[2] = 0;
    sb[0][0] = 8'h5A;                          // not a sync byte
    sb[0][1] = 8'hA5; sb[0][2] = 8'h03;
    for (n = 3; n < 1 + tlen(8'h03); n = n + 1) sb[0][n] = n[7:0];
    spos[0] = 0; spos[1] = 0; spos[2] = 0; no = 0; always_ready = 1; gap_en = 0;
    repeat (200) @(negedge clk);
    if (no != 1 + tlen(8'h03)) fail($sformatf("stray byte run: %0d bytes out, expected %0d", no, 1 + tlen(8'h03)));
    else begin
      if (ob[0] !== 8'h5A) fail("the stray byte did not pass through first");
      for (n = 1; n < no; n = n + 1) if (ob[n] !== sb[0][n]) fail($sformatf("stray run: byte %0d is %02x", n, ob[n]));
    end

    // ==== VERDICT ====
    if (errors != 0) $fatal(1, "TB_PC9821_DBG_MUX: %0d check(s) failed", errors);
    $display("TB_PC9821_DBG_MUX: PASS");
    $finish;
  end

  initial begin
    #40_000_000;
    $fatal(1, "the mux bench did not finish in 40 ms of simulated time");
  end
endmodule
