module uart_tx_V2(
    input wire clk,
    input wire [7:0] din,
    input wire wr_en,
    output wire tx_busy,

    output wire tx_p
);

// The line idles high from power-up. The value sits on an internal register: Quartus ignores a
// power-up value on an output port (docs/policies.md, the power-up rule).
reg tx_r = 1'b1;
assign tx_p = tx_r;

parameter clk_freq = 27000000;
parameter uart_freq = 115200;

localparam STATE_IDLE	= 2'b00;
localparam STATE_START	= 2'b01;
localparam STATE_DATA	= 2'b10;
localparam STATE_STOP	= 2'b11;

reg[7:0] localdin;
reg localwr_en;

//always@(posedge clk)begin
always@(*)begin	
    localdin<=din;
    localwr_en<=wr_en;
end

reg [7:0] data= 8'h00;
reg [2:0] bitpos= 3'h0;
reg [1:0] state= STATE_IDLE;

wire tx_clk;

localparam TX_CLK_MAX = (clk_freq / uart_freq)-1;

// THE COUNTER IS SIZED TO THE COUNTS IT HOLDS, not to two bits more. It only ever names
// 0..TX_CLK_MAX, so $clog2(TX_CLK_MAX+1) bits carry it - 9 at the top level's 50 MHz/115200
// (TX_CLK_MAX = 433), 11 at the MIDI card's 50 MHz/31250 - where a `+2` width would cost 11 and 13
// respectively. The one-bit floor keeps the width legal for a parameter set whose ratio rounds
// to zero or one, where $clog2 would return 0.
localparam integer TX_CLK_BITS = ($clog2(TX_CLK_MAX + 1) < 1) ? 1 : $clog2(TX_CLK_MAX + 1);

reg[TX_CLK_BITS-1:0] tx_clkcnt;

assign tx_clk = (tx_clkcnt == 0);

initial tx_clkcnt=0;

always @(posedge clk) begin
	if (tx_clkcnt >= TX_CLK_MAX)
		tx_clkcnt <= 0;
	else
		tx_clkcnt <= tx_clkcnt + 1;
end
	

always @(posedge clk) begin
	case (state)
	STATE_IDLE: begin
		if (localwr_en) begin
			state <= STATE_START;
			data <= localdin;
			bitpos <= 3'h0;
		end
	end
	STATE_START: begin
		if (tx_clk) begin
			tx_r <= 1'b0;
			state <= STATE_DATA;
		end
	end
	STATE_DATA: begin
		if (tx_clk) begin
			if (bitpos == 3'h7)
				state <= STATE_STOP;
			else
				bitpos <= bitpos + 3'h1;
			tx_r <= data[bitpos];
		end
	end
	STATE_STOP: begin
		if (tx_clk) begin
			tx_r <= 1'b1;
			state <= STATE_IDLE;
		end
	end
	default: begin
		tx_r <= 1'b1;
		state <= STATE_IDLE;
	end
	endcase
end

assign tx_busy = (state != STATE_IDLE);

endmodule
