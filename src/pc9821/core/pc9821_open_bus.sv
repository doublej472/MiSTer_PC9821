// Registered native-bus responder for absent memory regions.
// Acceptance and read response are deliberately separate cycles, matching the
// z486 external-memory contract and avoiding cache allocation via direct MMIO.

`default_nettype none

module pc9821_open_bus (
    input wire clk,
    input wire reset,
    input wire cpu_valid,
    input wire cpu_write,
    input wire cpu_line_read,
    output wire [31:0] cpu_dout,
    output reg cpu_ready,
    output reg cpu_resp_valid
);

  // A cache-line read is FOUR WORD BEATS of the constant all-ones word: the L1 gathers beat N
  // into line word N, so a fill from absent space is 4 x 32'hFFFF_FFFF. There is no 128-bit
  // line register. The word itself is the constant, not a register: a 32-bit register written
  // only with this value is "Stuck at VCC" in synthesis anyway, so the constant is value- and
  // cycle-identical. The constant is the open-bus datum
  // the machine shows for an absent read (pc9821_memory_subsystem's local_open_bus too).
  assign cpu_dout = 32'hFFFF_FFFF;
  localparam [2:0] S_IDLE = 3'd0, S_ACCEPT = 3'd1,
                   S_RESPONSE = 3'd2, S_LINE = 3'd3, S_HOLD = 3'd4;
  reg [2:0] state;
  reg [1:0] line_beat;
  reg request_write, request_line;

  always @(posedge clk) begin
    if (reset) begin
      state <= S_IDLE;
      line_beat <= 2'd0;
      request_write <= 1'b0;
      request_line <= 1'b0;
      cpu_ready <= 1'b0;
      cpu_resp_valid <= 1'b0;
    end else begin
      cpu_ready <= 1'b0;
      cpu_resp_valid <= 1'b0;
      case (state)
        S_IDLE: if (cpu_valid) begin
          request_write <= cpu_write;
          request_line <= cpu_line_read;
          state <= S_ACCEPT;
        end
        S_ACCEPT: begin
          cpu_ready <= 1'b1;
          state <= request_write ? S_HOLD : S_RESPONSE;
        end
        S_RESPONSE: begin
          // A word read answers here; a line read's four beats start the cycle after.
          if (request_line) begin
            line_beat <= 2'd0;
            state <= S_LINE;
          end else begin
            cpu_resp_valid <= 1'b1;
            state <= S_HOLD;
          end
        end
        // One beat per cycle of the constant word, four times.
        S_LINE: begin
          cpu_resp_valid <= 1'b1;
          line_beat <= line_beat + 2'd1;
          if (line_beat == 2'd3) state <= S_HOLD;
        end
        // One cycle only: the accept (a store) or the response (a read) was
        // delivered in the previous cycle. It must NOT wait for cpu_valid to
        // deassert -- a pipelined CPU need not present one request per valid, and
        // two back-to-back accesses to this route with valid held would deadlock
        // here. See pc9821_memory_subsystem.sv's responder contract.
        S_HOLD: state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
