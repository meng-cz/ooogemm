// Small static-array configuration used for cycle-level debugging.
// The implementation remains the production top_static; this wrapper only
// fixes the resource configuration used by the debug script.
`default_nettype none

module static_debug_top #(
    parameter int ADDR_WIDTH = 32,
    parameter int DIM_WIDTH = 16,
    parameter int UOP_FIFO_DEPTH = 32,
    parameter int GEMM_INSTID_WIDTH = 16,
    parameter int GEMM_TRACK_DEPTH = 256
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
    input logic [255:0] load_mem_rsp_data_i,
    output logic store_mem_wr_valid_o,
    input logic store_mem_wr_ready_i,
    output logic [ADDR_WIDTH-1:0] store_mem_wr_addr_o,
    output logic [31:0] store_mem_wr_data_o
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
        .UOP_FIFO_DEPTH(UOP_FIFO_DEPTH),
        .GEMM_INSTID_WIDTH(GEMM_INSTID_WIDTH),
        .GEMM_TRACK_DEPTH(GEMM_TRACK_DEPTH),
        .LOAD_DATA_WIDTH(256),
        .STORE_ROW_WRITE_BEATS(8)
    ) impl (.*);
endmodule

`default_nettype wire
