// check-equiv: functions ../../data_access.sv wb_wmask_of wb_view_hit_of
// data_access.sv vipt_load_wb_valid_r / _wmask_r / _view_hit_r: the next
// value formed without the kill (slow completion over EX hit) and the kill
// (q_flush || any_fault || interrupt_entry) applied last as a synchronous
// clear, against the single always_ff it was split from: cleared by default,
// set by an EX hit without a fault, set (later statement, so over it) by the
// slow completion, cleared by the kill, all under the synchronous reset.
// Both wb_*_of functions are the shipped text; every input is free.
// MUTANT=1 leaves interrupt_entry out of the kill and must be refuted.
module wb_kill_last #(parameter MUTANT = 0)
  (input reset_n, input ex_valid, input probed, input hit, input any_fault,
   input slow_wait, input servicing, input q_flush, input interrupt_entry,
   input [2:0] ex_dst, input [1:0] ex_size, input ex_alu,
   input [2:0] slow_dst, input [1:0] slow_size, input slow_alu, output mismatch);
// @@FUNCTIONS@@
  reg v_o; reg [7:0] m_o; reg [31:0] h_o;
  always @* begin
    if (!reset_n) begin v_o = 0; m_o = 0; h_o = 0; end
    else begin
      v_o = 0; m_o = 0; h_o = 0;
      if (ex_valid && probed && hit && !any_fault) begin
        v_o = 1; m_o = wb_wmask_of(ex_dst, ex_size); h_o = wb_view_hit_of(ex_dst, ex_size, ex_alu);
      end
      if (slow_wait && !servicing) begin
        v_o = 1; m_o = wb_wmask_of(slow_dst, slow_size); h_o = wb_view_hit_of(slow_dst, slow_size, slow_alu);
      end
      if (q_flush || any_fault || interrupt_entry) begin v_o = 0; m_o = 0; h_o = 0; end
    end
  end
  wire ex_done = ex_valid && probed && hit && !any_fault;
  wire slow_done = slow_wait && !servicing;
  wire kill = q_flush || any_fault || (MUTANT ? 1'b0 : interrupt_entry);
  wire v_nk = slow_done || ex_done;
  wire [7:0] m_nk = slow_done ? wb_wmask_of(slow_dst, slow_size) :
                    ex_done ? wb_wmask_of(ex_dst, ex_size) : 8'd0;
  wire [31:0] h_nk = slow_done ? wb_view_hit_of(slow_dst, slow_size, slow_alu) :
                     ex_done ? wb_view_hit_of(ex_dst, ex_size, ex_alu) : 32'd0;
  wire v_n = (!reset_n || kill) ? 1'b0 : v_nk;
  wire [7:0] m_n = (!reset_n || kill) ? 8'd0 : m_nk;
  wire [31:0] h_n = (!reset_n || kill) ? 32'd0 : h_nk;
  assign mismatch = (v_o != v_n) || (m_o != m_n) || (h_o != h_n);
endmodule
