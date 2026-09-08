`default_nettype none

// Standalone fdot synthesis top using the project-default exact accumulator.
module Fdot8e4m3_ACC96 (
    input  logic clk,
    input  logic rst_n,
    input  logic valid_i,
    input  logic [7:0] a_i,
    input  logic [7:0] b_i,
    input  logic first_i,
    input  logic last_i,
    input  logic [6:0] paccidx_i,
    input  logic accum_i,
    output logic valid_o,
    output logic signed [97:0] psum_sum_o,
    output logic signed [97:0] psum_carry_o,
    output logic psum_nan_o,
    output logic [6:0] paccidx_o,
    output logic accum_o
);

    fdot8e4m3 #(
        .ACC_WIDTH(96),
        .ACC_FRAC_BITS(18),
        .FDOT_CSA_WIDTH(98),
        .PACC_IDX_WIDTH(7)
    ) impl (.*);

endmodule

`default_nettype wire
