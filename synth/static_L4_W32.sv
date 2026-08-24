`default_nettype none

module L4_W32 (
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

    output logic load_mem_req_valid_o,
    input  logic load_mem_req_ready_i,
    output logic [31:0] load_mem_req_addr_o,
    output logic [5:0] load_mem_req_id_o,

    input  logic load_mem_rsp_valid_i,
    output logic load_mem_rsp_ready_o,
    input  logic [5:0] load_mem_rsp_id_i,
    input  logic [255:0] load_mem_rsp_data_i,

    output logic store_mem_wr_valid_o,
    input  logic store_mem_wr_ready_i,
    output logic [31:0] store_mem_wr_addr_o,
    output logic [31:0] store_mem_wr_data_o
);

    top_static #(
        .SA_WIDTH(32),
        .LANE_NUM(4),
        .ABUF_SIZE(64),
        .BBUF_SIZE(64),
        .PACC_NUM(16),
        .ADDR_WIDTH(32),
        .DIM_WIDTH(16),
        .UOP_FIFO_DEPTH(32),
        .STORE_ROW_WRITE_BEATS(32),
        .LANE_IDX_WIDTH(2),
        .ABUF_IDX_WIDTH(6),
        .BBUF_IDX_WIDTH(6),
        .PACC_IDX_WIDTH(4),
        .LOAD_BUS_ID_WIDTH(6),
        .ROW8_WIDTH(256),
        .ROW32_WIDTH(1024),
        .STORE_MEM_DATA_WIDTH(32),
        .GEMM_INSTID_WIDTH(16),
        .GEMM_TRACK_DEPTH(256),
        .OUTPUT_TRACK_DEPTH(32)
    ) u_top_static (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_valid_i(cmd_valid_i),
        .cmd_ready_o(cmd_ready_o),
        .cmd_a_base_i(cmd_a_base_i),
        .cmd_b_base_i(cmd_b_base_i),
        .cmd_c_base_i(cmd_c_base_i),
        .cmd_m_i(cmd_m_i),
        .cmd_n_i(cmd_n_i),
        .cmd_k_i(cmd_k_i),
        .cmd_batch_i(cmd_batch_i),
        .load_mem_req_valid_o(load_mem_req_valid_o),
        .load_mem_req_ready_i(load_mem_req_ready_i),
        .load_mem_req_addr_o(load_mem_req_addr_o),
        .load_mem_req_id_o(load_mem_req_id_o),
        .load_mem_rsp_valid_i(load_mem_rsp_valid_i),
        .load_mem_rsp_ready_o(load_mem_rsp_ready_o),
        .load_mem_rsp_id_i(load_mem_rsp_id_i),
        .load_mem_rsp_data_i(load_mem_rsp_data_i),
        .store_mem_wr_valid_o(store_mem_wr_valid_o),
        .store_mem_wr_ready_i(store_mem_wr_ready_i),
        .store_mem_wr_addr_o(store_mem_wr_addr_o),
        .store_mem_wr_data_o(store_mem_wr_data_o)
    );

endmodule

`default_nettype wire
