// check-equiv: functions ../../prefetch.sv ptr_idx d1_window
// prefetch.sv k1q_early[7:0] on a flush (the entry-ROM address byte): the
// target line's byte at spec_off picked last by spec_data_now, against the
// form it replaced, byte 0 of d1_window(queue_fl, spec_off[3:2], spec_off[1:0])
// with queue_fl seeded from spec_hit_line = spec_data_now ? pf_rdata : spec_line
// at every slot j >= spec_off[3:2]. d1_window and ptr_idx are the shipped text;
// the queue, both lines, spec_off, spec_data_now and the non-flush window are
// free. MUTANT=1 reads the held line's byte at spec_off+1 and must be refuted.
module flush_byte0_late #(parameter MUTANT = 0)
  (input [255:0] pq, input [127:0] pf_rdata, input [127:0] spec_line,
   input [3:0] spec_off, input sdn, input q_flush, input [7:0] nf, output mismatch);
// @@FUNCTIONS@@
  // old
  wire [127:0] hit_line = sdn ? pf_rdata : spec_line;
  reg [255:0] queue_fl;
  integer j;
  always @* begin
    queue_fl = pq;
    for (j = 0; j < 4; j = j + 1)
      if (j[1:0] >= spec_off[3:2])
        queue_fl[32*j +: 32] = hit_line[32*j +: 32];
  end
  wire [63:0] fl = d1_window(queue_fl, {2'b00, spec_off[3:2]}, spec_off[1:0]);
  wire [7:0] old_b = q_flush ? fl[7:0] : nf;
  // new
  wire [3:0] hoff = MUTANT ? spec_off + 4'd1 : spec_off;
  wire [7:0] b_ack  = pf_rdata[{spec_off, 3'b000} +: 8];
  wire [7:0] b_held = spec_line[{hoff, 3'b000} +: 8];
  wire [7:0] new_b = q_flush ? (sdn ? b_ack : b_held) : nf;
  assign mismatch = old_b != new_b;
endmodule
