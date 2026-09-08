`default_nettype none

// Standalone three-stream static parser for the common AB32/ACC128 setup.
module StaticUopParse_M16_N16_K32_AB32_ACC128 (
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
    input  logic [4:0] block_m_i,
    input  logic [4:0] block_n_i,
    output logic load_valid_o,
    input  logic load_ready_i,
    output logic load_is_b_o,
    output logic load_group_o,
    output logic [31:0] load_addr_o,
    output logic [4:0] load_abufidx_o,
    output logic [4:0] load_bbufidx_o,
    output logic [4:0] load_valid_rows_o,
    output logic gemm_valid_o,
    input  logic gemm_ready_i,
    output logic gemm_group_o,
    output logic [4:0] gemm_abufidx_o,
    output logic [4:0] gemm_bbufidx_o,
    output logic [6:0] gemm_paccidx_o,
    output logic gemm_accum_o,
    output logic output_valid_o,
    input  logic output_ready_i,
    output logic output_group_o,
    output logic [31:0] output_addr_o,
    output logic [6:0] output_paccidx_o,
    input  logic load_done_valid_i,
    input  logic gemm_done_valid_i,
    input  logic output_done_valid_i,
    output logic cmd_done_valid_o
);

    new_static_uopparse #(
        .SA_WIDTH(16),
        .SUBTILE_M(16),
        .SUBTILE_N(16),
        .SUBTILE_K(32),
        .ABUF_SIZE(32),
        .BBUF_SIZE(32),
        .PACC_NUM(128),
        .ADDR_WIDTH(32),
        .DIM_WIDTH(16),
        .ABUF_IDX_WIDTH(5),
        .BBUF_IDX_WIDTH(5),
        .PACC_IDX_WIDTH(7),
        .LOAD_ROWS_WIDTH(5),
        .BLOCK_M_WIDTH(5),
        .BLOCK_N_WIDTH(5),
        .COUNT_WIDTH(16)
    ) impl (.*);

endmodule

`default_nettype wire
