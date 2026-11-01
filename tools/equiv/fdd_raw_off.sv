// SPAN: src/pc9821/storage/pc9821_fdd_media.sv | wire [ 8:0] a_track9 | (raw_secno <<  9);
// PLANT: {req_tc, 1'b0} | {8'd0, req_hd} => {req_tc, 1'b0}
// PLANT: + (a_sects[7] ? (a_t9e << 7) : 17'd0); => + (a_sects[7] ? (a_t9e << 6) : 17'd0);
// Combinational proof for pc9821_fdd_media's FD-a seam: the raw file offset formed from the
// request's LIVE fields at the accept (raw_off_a - the REAL text, pasted by the SPAN line) equals
// the offset formed from the rq_* latches and req_u (ad9ed84c's text below), for every physical
// track / head / R and every geometry byte, when the latches hold what the accept loaded into
// them (rq_tc = req_tc, rq_hd = req_hd, rq_r = req_r, req_u = unit[0]) - which is the state in
// ST_SEEK, the offset's only reader. THE TRACK IS THE HEAD'S, NOT THE COMMAND'S C/H: the raw
// reader locates a sector on the physical track (NP2kai diskimage/fddfile.c fdd_seeksector_common
// takes `fdc.treg[fdc.us]` and `fdc.hd`), so the seam carries req_tc/req_hd (the drive's track
// register and the head) and the latched track is the module's own rq_track
// (`({24'd0, rq_tc} << 1) | {31'd0, rq_hd}`); ad9ed84c's form below is restated on those fields. The latch-timing half of the argument is pinned cycle-by-cycle by
// tb_pc9821_fdd_media_equiv against the pre-change module.
module m(input [7:0] req_tc, req_r, input req_hd, input [1:0] unit,
         input [7:0] sects0, sects1, n0, n1, output mismatch);
  localparam [7:0] RAW_N1 = 8'd1, RAW_N2 = 8'd2, RAW_N3 = 8'd3;
  wire [7:0] raw_sects [0:1];
  wire [7:0] raw_n [0:1];
  assign raw_sects[0] = sects0; assign raw_sects[1] = sects1;
  assign raw_n[0] = n0; assign raw_n[1] = n1;
  // SPAN-HERE
  // ---- the latched wiring (ad9ed84c), verbatim but for the latch renames and the track source ----
  wire [7:0] rq_tc = req_tc, rq_r = req_r;
  wire       rq_hd = req_hd;
  wire       req_u = unit[0];
  wire [31:0] rq_track = ({24'd0, rq_tc} << 1) | {31'd0, rq_hd};
  wire [ 8:0] rq_track9  = rq_track[8:0];
  wire [16:0] rq_t9e     = {8'd0, rq_track9};
  wire [16:0] o_raw_ts   = (raw_sects[req_u][0] ? rq_t9e        : 17'd0)
                         + (raw_sects[req_u][1] ? (rq_t9e << 1) : 17'd0)
                         + (raw_sects[req_u][2] ? (rq_t9e << 2) : 17'd0)
                         + (raw_sects[req_u][3] ? (rq_t9e << 3) : 17'd0)
                         + (raw_sects[req_u][4] ? (rq_t9e << 4) : 17'd0)
                         + (raw_sects[req_u][5] ? (rq_t9e << 5) : 17'd0)
                         + (raw_sects[req_u][6] ? (rq_t9e << 6) : 17'd0)
                         + (raw_sects[req_u][7] ? (rq_t9e << 7) : 17'd0);
  wire [24:0] o_raw_secno = {8'd0, o_raw_ts} + {17'd0, rq_r} - 25'd1;
  wire [24:0] o_raw_off  = (raw_n[req_u] == RAW_N1) ? (o_raw_secno <<  8) :
                           (raw_n[req_u] == RAW_N3) ? (o_raw_secno << 10) :
                                                      (o_raw_secno <<  9);
  assign mismatch = o_raw_off != raw_off_a;
endmodule
