/* This file is part of JT12.


    JT12 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT12 program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT12.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 21-03-2019
*/

module jt12_rst(
    input   rst,
    input   clk,
    input   rst_nx,     // LOCAL PATCH (rst_nx seam, PC-98 core): rst one cycle early (below)
    output  reg rst_n
);

reg r;

// LOCAL PATCH (PC-98 core, timing): upstream registers this two-stage synchroniser on the
// FALLING edge of clk from rst:
//     always @(negedge clk) if( rst ) {rst_n, r} <= 2'b00; else { rst_n, r } <= { r, 1'b1 };
// so rst_n, the ADPCM-A/B blocks' reset net (asynchronous in most of them, synchronous in
// jt08_adpcm_drvB and jt08_adpcmb_interpol), had half a clk period to reach its loads: +0.55 ns
// and +0.60 ns of setup slack on two of six seeds of the base build at 90 MHz, the narrowest
// half-cycle path left in the chip. A rising-edge reader sees, at each rising edge, what the
// last falling edge loaded: rst_n = !rst(this cycle) && !rst(the cycle before). Here both
// stages load on the RISING edge from rst_nx, the value rst takes at that edge (pc9821_opna's
// op_rst next state), so each loads one edge earlier with the value upstream's falling edge
// latched and every rising-edge reader sees what it saw before; rst_n is now a full-cycle path.
// tb_pc9821_opna_cen holds rst_n equal to a verbatim copy of the upstream module at every rising
// edge, and the assertion below holds the seam to rst.
always @(posedge clk)
    if( rst_nx ) begin
        r     <= 1'b0;
        rst_n <= 1'b0;
    end else begin
        { rst_n, r } <= { r, 1'b1 };
    end

`ifndef SYNTHESIS
// The seam's contract: rst_nx is rst one cycle early.
reg rst_nx_q, seam_live;
initial begin rst_nx_q = 1'b0; seam_live = 1'b0; end
always @(posedge clk) begin
    rst_nx_q  <= rst_nx;
    seam_live <= 1'b1;
    if( seam_live && (rst !== rst_nx_q) )
        $error("jt12_rst: rst_nx is not rst one cycle early (the LOCAL PATCH seam)");
end
`endif

endmodule // jt12_rst
