`default_nettype none

// Standalone dynamic parser using the largest common logical resource set.
module DynamicUopParse_M16_N16_K32_AB24_ACC96 (
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
    output logic uop_valid_o,
    input  logic uop_ready_i,
    output logic [2:0] uop_type_o,
    output logic [31:0] uop_addr_o,
    output logic [4:0] uop_abufidx_o,
    output logic [4:0] uop_bbufidx_o,
    output logic [6:0] uop_paccidx_o,
    output logic [4:0] uop_valid_rows_o,
    output logic uop_accum_o
);

    uopparse_pkg::uop_type_e uop_type;
    assign uop_type_o = uop_type;

    dynamic_uopparse #(
        .SA_WIDTH(16),
        .SUBTILE_M(16),
        .SUBTILE_N(16),
        .SUBTILE_K(32),
        .ABUF_SIZE(32),
        .BBUF_SIZE(32),
        .PACC_NUM(128),
        .ABUF_LOGIC_SIZE(24),
        .BBUF_LOGIC_SIZE(24),
        .PACC_LOGIC_SIZE(96),
        .ADDR_WIDTH(32),
        .DIM_WIDTH(16),
        .ABUF_IDX_WIDTH(5),
        .BBUF_IDX_WIDTH(5),
        .PACC_IDX_WIDTH(7),
        .LOAD_ROWS_WIDTH(5),
        .BLOCK_M_WIDTH(5),
        .BLOCK_N_WIDTH(5)
    ) impl (
        .uop_type_o(uop_type),
        .*
    );

endmodule

`default_nettype wire
