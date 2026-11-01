// SPDX-License-Identifier: BSD-2-Clause
// Copyright (c) 2014, Aleksander Osman, and the ao486_MiSTer contributors.
// From ao486_MiSTer rtl/common/synchronizer.sv
// (https://github.com/MiSTer-devel/ao486_MiSTer). Licence text: NOTICE, part 4.

// `timescale 1ns / 1ps

`default_nettype none

module synchronizer #(
    parameter DATA_WIDTH = 1
) (
    input clk,   // clock domain of out
    input [DATA_WIDTH-1:0] in,
    output reg [DATA_WIDTH-1:0] out
);
    // Keep both stages as colocated synchronizer registers, identified as such to the
    // fitter so register duplication/retiming cannot restructure the chain. The attribute
    // is the Quartus spelling: the Xilinx ASYNC_REG that stood here is unrecognised by
    // Quartus 17 - Warning (10335) - so the
    // fitter never saw the intent and only the automatic Synchronizer Identification pass
    // covered it. The same conversion was already made on the (since removed) SDRAM clock
    // bridge's reset chain; this is the shared module the CDC inventory's rows depend on.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) logic [1:0] [DATA_WIDTH-1:0] sync_regs = 0;

    always_ff @(posedge clk)
    	{sync_regs[1], sync_regs[0]} <= {sync_regs[0], in};

    always_comb out = sync_regs[1];
endmodule

`default_nettype wire
