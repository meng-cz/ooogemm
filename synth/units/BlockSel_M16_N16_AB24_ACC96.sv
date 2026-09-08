`default_nettype none

// Standalone runtime block selector.  AB24/ACC96 exercises non-power-of-two
// resource bounds used by the dynamic scheduling experiments.
module BlockSel_M16_N16_AB24_ACC96 (
    input  logic clk,
    input  logic rst_n,
    input  logic cmd_valid_i,
    output logic cmd_ready_o,
    input  logic [31:0] cmd_a_base_i,
    input  logic [31:0] cmd_b_base_i,
    input  logic [31:0] cmd_c_base_i,
    input  logic [15:0] cmd_m_i,
    input  logic [15:0] cmd_n_i,
    input  logic [15:0] cmd_k_i,
    input  logic [15:0] cmd_batch_i,
    output logic gemm_valid_o,
    input  logic gemm_ready_i,
    output logic [31:0] gemm_a_base_o,
    output logic [31:0] gemm_b_base_o,
    output logic [31:0] gemm_c_base_o,
    output logic [15:0] gemm_m_o,
    output logic [15:0] gemm_n_o,
    output logic [15:0] gemm_k_o,
    output logic [15:0] gemm_batch_o,
    output logic [4:0] block_m_o,
    output logic [4:0] block_n_o
);

    blocksel #(
        .SA_WIDTH(16),
        .SUBTILE_M(16),
        .SUBTILE_N(16),
        .LOGIC_ABUF_SIZE(24),
        .LOGIC_BBUF_SIZE(24),
        .LOGIC_ACC_NUM(96),
        .ADDR_WIDTH(32),
        .DIM_WIDTH(16),
        .UNROLL_NUM(1),
        .BLOCK_M_WIDTH(5),
        .BLOCK_N_WIDTH(5)
    ) impl (.*);

endmodule

`default_nettype wire
