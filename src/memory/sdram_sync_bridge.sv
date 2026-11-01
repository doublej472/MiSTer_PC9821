// The SDRAM bridge: the controller on the requesters' own clock (clk_sys), no crossing. The
// controller and its PHY run on clk_sys and its FREQ is clk_sys's rate, so sdram.v derives its
// CAS/tRCD/tRP/tRC/tWR/refresh cycle counts for that clock. ("sync" in the name: same clock.)
//
// THE REQUESTER-SIDE CONTRACT: `valid` is held, with its payload stable, until the one-cycle
// `ready`; a read answers one `resp_valid` pulse per dword, to the port that asked; `dout0` holds
// port 0's last word between its pulses, and `dout1..3` are valid in their own resp_valid cycle.
// Every one of those is a property the controller already has on its own clock (sdram.v's port
// comments: `ready` is a registered 1-cycle pulse at the accept, `resp_valid` a registered pulse
// per completed 32-bit word, routed by req_id_buf) EXCEPT the port-0 hold: sdram.v keeps ONE
// completed word for all four ports (`dout_word`). So this module is the controller plus that one
// hold register, and nothing else.
`default_nettype none

module sdram_sync_bridge #(
    parameter FREQ = 50_000_000,      // the controller's clock = `clk`'s rate in this build
    parameter ADQM = 1'b0,
    parameter FAST_GRADE = 1'b1,
    parameter integer GATHER_K = 4,
    parameter DQ_IN_DDIO = 1'b0,      // sdram.v's DQ read-capture cell (its parameter note)
    parameter OUT_DDIO = 1'b0,        // sdram.v's output-register cells (its parameter note)
    parameter integer DBG_CL = 0,           // sdram.v's measurement overrides (its parameter note)
    parameter integer DBG_TRCD_TRP = 0
) (
    input                   clk,          // requesters AND controller + PHY (clk_sys)
    input                   resetn,
    input                   refresh_allowed,
    output                  busy,
    input  [1:0]            sdram_size,

    input                   valid0,
    output                  ready0,
    input                   wr0,
    input  [26:0]           addr0,
    input  [31:0]           din0,
    input  [31:0]           din0_hi,
    input                   gath0,
    input  [440:0]          gath0_extra,
    output [31:0]           dout0,
    input  [3:0]            be0,
    output                  resp_valid0,
    input  [3:0]            burst_cnt0,

    input                   valid1,
    output                  ready1,
    input                   wr1,
    input  [26:0]           addr1,
    input  [31:0]           din1,
    output [31:0]           dout1,
    input  [3:0]            be1,
    output                  resp_valid1,
    input  [3:0]            burst_cnt1,

    input                   valid2,
    output                  ready2,
    input                   wr2,
    input  [26:0]           addr2,
    input  [31:0]           din2,
    output [31:0]           dout2,
    input  [3:0]            be2,
    output                  resp_valid2,
    input  [3:0]            burst_cnt2,

    input                   valid3,
    output                  ready3,
    input                   wr3,
    input  [26:0]           addr3,
    input  [31:0]           din3,
    output [31:0]           dout3,
    input  [3:0]            be3,
    output                  resp_valid3,
    input  [3:0]            burst_cnt3,

    inout  [15:0]           SDRAM_DQ,
    output [12:0]           SDRAM_A,
    output [1:0]            SDRAM_DQM,
    output [1:0]            SDRAM_BA,
    output                  SDRAM_nWE,
    output                  SDRAM_nRAS,
    output                  SDRAM_nCAS,
    output                  SDRAM_nCS,
    output                  SDRAM_CKE
);

wire [31:0] ctrl_dout0;
wire        ctrl_resp0;

/* verilator lint_off PINCONNECTEMPTY */   // burst_done has no consumer (split_sdram_backend)
sdram #(
    .FREQ(FREQ),
    .ADQM(ADQM),
    .FAST_GRADE(FAST_GRADE),
    .GATHER_K(GATHER_K),
    .DQ_IN_DDIO(DQ_IN_DDIO),
    .OUT_DDIO(OUT_DDIO),
    .DBG_CL(DBG_CL),
    .DBG_TRCD_TRP(DBG_TRCD_TRP)
) ctrl (
    .clk(clk),
    .resetn(resetn),
    .nce(1'b0),
    .refresh_allowed(refresh_allowed),
    .busy(busy),
    .sdram_size(sdram_size),

    .valid0(valid0), .ready0(ready0), .wr0(wr0), .addr0(addr0),
    .din0(din0), .din0_hi(din0_hi), .gath0(gath0), .gath0_extra(gath0_extra),
    .dout0(ctrl_dout0), .resp_valid0(ctrl_resp0), .be0(be0),
    .burst_cnt0(burst_cnt0), .burst_done0(),
    .valid1(valid1), .ready1(ready1), .wr1(wr1), .addr1(addr1),
    .din1(din1), .dout1(dout1), .resp_valid1(resp_valid1), .be1(be1),
    .burst_cnt1(burst_cnt1), .burst_done1(),
    .valid2(valid2), .ready2(ready2), .wr2(wr2), .addr2(addr2),
    .din2(din2), .dout2(dout2), .resp_valid2(resp_valid2), .be2(be2),
    .burst_cnt2(burst_cnt2), .burst_done2(),
    .valid3(valid3), .ready3(ready3), .wr3(wr3), .addr3(addr3),
    .din3(din3), .dout3(dout3), .resp_valid3(resp_valid3), .be3(be3),
    .burst_cnt3(burst_cnt3), .burst_done3(),

    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQM(SDRAM_DQM), .SDRAM_BA(SDRAM_BA),
    .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_CKE(SDRAM_CKE)
);
/* verilator lint_on PINCONNECTEMPTY */

// ---- port 0's hold ----
// Port 0 fans out to several readers inside pc9821_memory_subsystem (the CPU's response mux, the
// DMA byte select, the PEGC store buffer's passthrough), which read the last port-0 word between
// pulses. The controller's `dout_word` is overwritten by
// the next completed word of ANY port, so without this register a port-1..3 response landing
// between two port-0 reads would show through on dout0. In the resp_valid0 cycle the new word is
// passed straight through, and the register keeps it afterwards. It is 32 flops, no memory, so a
// reset value costs no inference; reset clears it.
reg [31:0] port0_hold;
always @(posedge clk) begin
    if (!resetn)         port0_hold <= 32'd0;
    else if (ctrl_resp0) port0_hold <= ctrl_dout0;
end
assign dout0       = ctrl_resp0 ? ctrl_dout0 : port0_hold;
assign resp_valid0 = ctrl_resp0;

// ---- the requester contract, ASSERTED ----
// With no crossing the controller samples a port's payload on WHICHEVER cycle its arbiter takes
// the request, so a requester must hold `valid` and the whole payload from the first valid cycle
// until its ready. A requester that
// drops valid early, or moves its payload under a held valid, would be served the moved payload
// (or not at all), so it fails loudly in simulation instead.
`ifdef VERILATOR
localparam integer REQ_PAYLOAD_W = 1 + 27 + 32 + 32 + 1 + 441 + 4 + 4;
wire [3:0] req_valid = {valid3, valid2, valid1, valid0};
wire [3:0] req_ready = {ready3, ready2, ready1, ready0};
// Port 0's two payload fields that only some requests read are qualified here, because the
// controller reads them only then: din0_hi is the second word of a two-word write (burst 2, not
// a gather), and gath0_extra entry j (1..) is read only for j < burst_cnt0 of a gather (sdram.v's
// slot maps count entries below mn_ns, and its row contract checks the same range). A requester
// may leave the unread slots unqualified (pc9821_pegc_storebuf's head window does), so a move in
// an unread slot is not a moved payload.
reg [440:0] gath0_extra_used;
always @* begin : gath0_used
    integer gj;
    gath0_extra_used = 441'd0;
    for (gj = 1; gj < 8; gj = gj + 1)
        if (gath0 && (4'(gj) < ((burst_cnt0 == 4'd0) ? 4'd1 : burst_cnt0)))
            gath0_extra_used[(gj-1)*63 +: 63] = gath0_extra[(gj-1)*63 +: 63];
end
wire [31:0] din0_hi_used = (wr0 && !gath0 && (burst_cnt0 == 4'd2)) ? din0_hi : 32'd0;
wire [3:0][REQ_PAYLOAD_W-1:0] req_payload = {
    {wr3, addr3, din3, 32'd0, 1'b0, 441'd0, be3, burst_cnt3},
    {wr2, addr2, din2, 32'd0, 1'b0, 441'd0, be2, burst_cnt2},
    {wr1, addr1, din1, 32'd0, 1'b0, 441'd0, be1, burst_cnt1},
    {wr0, addr0, din0, din0_hi_used, gath0, gath0_extra_used, be0, burst_cnt0}};
reg [3:0]                     waiting;   // valid seen, ready not yet delivered
reg [3:0][REQ_PAYLOAD_W-1:0]  held_payload;
always @(posedge clk) begin
    if (!resetn) begin
        waiting      <= 4'b0000;
        held_payload <= '0;
    end else begin
        for (int p = 0; p < 4; p = p + 1) begin
            if (waiting[p] && !req_ready[p]) begin
                if (!req_valid[p])
                    $fatal(1, "sdram_sync_bridge: port %0d dropped valid before its ready - the controller has no launched copy of the request in the same-clock build", p);
                if (req_payload[p] !== held_payload[p])
                    $fatal(1, "sdram_sync_bridge: port %0d moved its request payload under a held valid - the controller samples it on the cycle it takes the request", p);
            end
            // A new request may be presented on the cycle after the ready.
            waiting[p] <= req_valid[p] && !req_ready[p];
            if (req_valid[p] && !waiting[p]) held_payload[p] <= req_payload[p];
        end
    end
end
`endif

endmodule

`default_nettype wire
