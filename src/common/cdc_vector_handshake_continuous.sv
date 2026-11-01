// SPDX-License-Identifier: BSD-2-Clause
// Copyright (c) 2014, Aleksander Osman, and the ao486_MiSTer contributors.
// From ao486_MiSTer rtl/common/cdc_vector_handshake_continuous.sv
// (https://github.com/MiSTer-devel/ao486_MiSTer). Licence text: NOTICE, part 4.

/*
Can be used in place of asynchronous FIFO for applications with infrequent transitions
to pass vector across CDC. Continuously passes value across but holds current value for
single bit synchronized handshaking feedback loop. Works for both fast->slow and
slow->fast clock differences.
*/
// `timescale 1ns / 1ps
`default_nettype none

module cdc_vector_handshake_continuous #(
    parameter DATA_WIDTH = 0
) (
    input wire clk_in,
    input wire clk_out,
    input wire [DATA_WIDTH-1:0] data_in,
    output logic [DATA_WIDTH-1:0] data_out = 0
);
    logic [DATA_WIDTH-1:0] data_hold_clk_in = 0;
    logic new_value_clk_in = 0;
    logic new_value_clk_out;
    logic ack_clk_in;

    always_ff @(posedge clk_in)
        if (ack_clk_in)
            new_value_clk_in <= 0;
        else if (!new_value_clk_in) begin
            new_value_clk_in <= 1;
            data_hold_clk_in <= data_in;
        end

    // The two handshake flags are one bit each, so both synchronizers are pinned to width 1
    // rather than inheriting this module's DATA_WIDTH (the data word crosses through
    // data_hold_clk_in, not through a synchronizer).
    synchronizer #(.DATA_WIDTH(1)) new_value_sync (
        .clk(clk_out),
        .in(new_value_clk_in),
        .out(new_value_clk_out)
    );

    synchronizer #(.DATA_WIDTH(1)) ack_sync (
        .clk(clk_in),
        .in(new_value_clk_out),
        .out(ack_clk_in)
    );

    always_ff @(posedge clk_out)
        if (new_value_clk_out)
            data_out <= data_hold_clk_in;
endmodule
`default_nettype wire