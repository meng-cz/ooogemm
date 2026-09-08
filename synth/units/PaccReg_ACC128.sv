`default_nettype none

// Standalone PACC synthesis top for the common 128-entry configuration.
module PaccReg_ACC128 (
    input  logic clk,
    input  logic rst_n,
    input  logic valid_i,
    input  logic signed [97:0] psum_sum_i,
    input  logic signed [97:0] psum_carry_i,
    input  logic psum_nan_i,
    input  logic [6:0] paccidx_i,
    input  logic accum_i,
    input  logic getacc_i,
    input  logic [6:0] getacc_idx_i,
    output logic getacc_o,
    output logic [31:0] getacc_data_o
);

    paccreg #(
        .PACC_NUM(128),
        .PACC_IDX_WIDTH(7),
        .PACC_EXP_WIDTH(10),
        .PACC_SIG_WIDTH(40),
        .FDOT_ACC_WIDTH(96),
        .FDOT_ACC_FRAC_BITS(18),
        .FDOT_CSA_WIDTH(98)
    ) impl (.*);

endmodule

`default_nettype wire
