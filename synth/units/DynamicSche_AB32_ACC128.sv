`default_nettype none

// Standalone OoO scheduler using the common 32-entry operand buffers and
// 128-entry physical PACC file.
module DynamicSche_AB32_ACC128 (
    input  logic clk,
    input  logic rst_n,
    input  logic uop_valid_i,
    output logic uop_ready_o,
    input  logic [2:0] uop_type_i,
    input  logic [31:0] uop_addr_i,
    input  logic [4:0] uop_abufidx_i,
    input  logic [4:0] uop_bbufidx_i,
    input  logic [6:0] uop_paccidx_i,
    input  logic [4:0] uop_valid_rows_i,
    input  logic uop_accum_i,
    output logic load_valid_o,
    input  logic load_ready_i,
    output logic [2:0] load_type_o,
    output logic [31:0] load_addr_o,
    output logic [4:0] load_abufidx_o,
    output logic [4:0] load_bbufidx_o,
    output logic [4:0] load_valid_rows_o,
    output logic gemm_valid_o,
    input  logic gemm_ready_i,
    output logic [4:0] gemm_abufidx_o,
    output logic [4:0] gemm_bbufidx_o,
    output logic [6:0] gemm_paccidx_o,
    output logic gemm_accum_o,
    output logic output_valid_o,
    input  logic output_ready_i,
    output logic [31:0] output_addr_o,
    output logic [6:0] output_paccidx_o,
    input  logic load_a_done_valid_i,
    input  logic [4:0] load_a_done_phys_i,
    input  logic load_b_done_valid_i,
    input  logic [4:0] load_b_done_phys_i,
    input  logic gemm_done_valid_i,
    input  logic [6:0] gemm_done_paccidx_i,
    input  logic output_done_valid_i,
    input  logic [6:0] output_done_paccidx_i
);

    uopparse_pkg::uop_type_e uop_type;
    uopparse_pkg::uop_type_e load_type;
    assign uop_type = uopparse_pkg::uop_type_e'(uop_type_i);
    assign load_type_o = load_type;

    dynamic_sche #(
        .ABUF_PHYS_SIZE(32),
        .BBUF_PHYS_SIZE(32),
        .PACC_PHYS_SIZE(128),
        .ADDR_WIDTH(32),
        .LOAD_ROWS_WIDTH(5),
        .LOAD_QUEUE_DEPTH(16),
        .GEMM_SLOT_DEPTH(16),
        .SLOT_ACC_COUNT(4),
        .ABUF_PHYS_IDX_WIDTH(5),
        .BBUF_PHYS_IDX_WIDTH(5),
        .PACC_PHYS_IDX_WIDTH(7),
        .USE_COUNT_WIDTH(16),
        .SLOT_COUNT(32),
        .LOAD_PTR_WIDTH(4),
        .GEMM_PTR_WIDTH(4),
        .SLOT_IDX_WIDTH(5)
    ) impl (
        .uop_type_i(uop_type),
        .load_type_o(load_type),
        .*
    );

endmodule

`default_nettype wire
