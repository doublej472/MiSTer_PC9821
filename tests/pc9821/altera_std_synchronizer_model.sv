// The Quartus megafunction `altera_std_synchronizer` (depth-stage synchronizer) as a plain
// simulation model: sys/pll_cfg/pll_cfg_hdmi.v and altera_pll_reconfig_core.v instantiate it,
// and Quartus resolves it from /opt/intelFPGA/quartus/libraries/megafunctions/
// altera_std_synchronizer.v, which is not in this repository. Behaviour: `dout` is `din` delayed
// by `depth` clocks, cleared while `reset_n` is low.
//
// This file is NOT part of the design and must never be added to a build list. Only
// tb_pc9821_pll_cfg_lockstep (which elaborates the two real reconfiguration cores) uses it.
module altera_std_synchronizer #(
	parameter integer depth = 3
) (
	input  wire clk,
	input  wire reset_n,
	input  wire din,
	output wire dout
);
	reg [depth-1:0] sync;
	integer i;
	always @(posedge clk or negedge reset_n) begin
		if (!reset_n)
			sync <= '0;
		else begin
			sync[0] <= din;
			for (i = 1; i < depth; i = i + 1)
				sync[i] <= sync[i-1];
		end
	end
	assign dout = sync[depth-1];
endmodule
