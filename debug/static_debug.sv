// Small static-array configuration used for cycle-level debugging.
// The implementation remains the production top_static; this wrapper only
// fixes the resource configuration used by the debug script.
`default_nettype none

module static_debug_top #(
    parameter int ADDR_WIDTH = 32,
    parameter int DIM_WIDTH = 16,
    parameter int GEMM_INSTID_WIDTH = 16,
    parameter int COUNT_WIDTH = 16
) (
    input  logic clk,
    input  logic rst_n,
    input  logic cmd_valid_i,
    output logic cmd_ready_o,
    input  logic [ADDR_WIDTH-1:0] cmd_a_base_i,
    input  logic [ADDR_WIDTH-1:0] cmd_b_base_i,
    input  logic [ADDR_WIDTH-1:0] cmd_c_base_i,
    input  logic [DIM_WIDTH-1:0] cmd_m_i,
    input  logic [DIM_WIDTH-1:0] cmd_n_i,
    input  logic [DIM_WIDTH-1:0] cmd_k_i,
    input  logic [DIM_WIDTH-1:0] cmd_batch_i,
    output logic load_mem_req_valid_o,
    input logic load_mem_req_ready_i,
    output logic [ADDR_WIDTH-1:0] load_mem_req_addr_o,
    output logic [2:0] load_mem_req_id_o,
    input logic load_mem_rsp_valid_i,
    output logic load_mem_rsp_ready_o,
    input logic [2:0] load_mem_rsp_id_i,
    input logic [1023:0] load_mem_rsp_data_i,
    output logic store_mem_wr_valid_o,
    input logic store_mem_wr_ready_i,
    output logic [ADDR_WIDTH-1:0] store_mem_wr_addr_o,
    output logic [255:0] store_mem_wr_data_o
);
    top_static #(
        .SA_WIDTH(8),
        .SUBTILE_K(16),
        .LANE_NUM(1),
        .ABUF_SIZE(4),
        .BBUF_SIZE(4),
        .PACC_NUM(4),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DIM_WIDTH(DIM_WIDTH),
        .GEMM_INSTID_WIDTH(GEMM_INSTID_WIDTH),
        .COUNT_WIDTH(COUNT_WIDTH),
        .LOAD_DATA_WIDTH(1024),
        .STORE_ROWS_PER_CYCLE(1)
    ) impl (.*);
endmodule

`default_nettype wire
