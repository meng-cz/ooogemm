`default_nettype none

// Fixed synthesis wrapper for the static static_L16_W16_AB32_ACC128 experiment configuration.
module static_L16_W16_AB32_ACC128 #(
    parameter int SA_WIDTH = 16,
    parameter int SUBTILE_M = 16,
    parameter int SUBTILE_N = 16,
    parameter int SUBTILE_K = 32,
    parameter int LANE_NUM = 16,
    parameter int ABUF_SIZE = 32,
    parameter int BBUF_SIZE = 32,
    parameter int PACC_NUM = 128,
    parameter int ADDR_WIDTH = 32,
    parameter int DIM_WIDTH = 16,
    parameter int STORE_ROWS_PER_CYCLE = 4,
    parameter int LOAD_DATA_WIDTH = 1024,
    parameter int LANE_IDX_WIDTH = (LANE_NUM <= 1) ? 1 : $clog2(LANE_NUM),
    parameter int ABUF_IDX_WIDTH = (ABUF_SIZE <= 1) ? 1 : $clog2(ABUF_SIZE),
    parameter int BBUF_IDX_WIDTH = (BBUF_SIZE <= 1) ? 1 : $clog2(BBUF_SIZE),
    parameter int PACC_IDX_WIDTH = (PACC_NUM <= 1) ? 1 : $clog2(PACC_NUM),
    parameter int ROW8_WIDTH = SUBTILE_K * 8,
    parameter int MAX_SUBTILE_ROWS = (SUBTILE_M > SUBTILE_N) ? SUBTILE_M : SUBTILE_N,
    parameter int LOAD_BUS_ID_WIDTH =
        ((MAX_SUBTILE_ROWS * ((ROW8_WIDTH >= LOAD_DATA_WIDTH) ?
          (ROW8_WIDTH / LOAD_DATA_WIDTH) : 1)) <= 1) ? 1 :
        $clog2(MAX_SUBTILE_ROWS * ((ROW8_WIDTH >= LOAD_DATA_WIDTH) ?
          (ROW8_WIDTH / LOAD_DATA_WIDTH) : 1)),
    parameter int ROW32_WIDTH = SUBTILE_N * 32,
    parameter int LOAD_ROWS_WIDTH = (MAX_SUBTILE_ROWS <= 1) ? 1 : $clog2(MAX_SUBTILE_ROWS + 1),
    parameter int STORE_MEM_DATA_WIDTH = ROW32_WIDTH * STORE_ROWS_PER_CYCLE,
    parameter int GEMM_INSTID_WIDTH = 16
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
    input  logic load_mem_req_ready_i,
    output logic [ADDR_WIDTH-1:0] load_mem_req_addr_o,
    output logic [LOAD_BUS_ID_WIDTH-1:0] load_mem_req_id_o,
    input  logic load_mem_rsp_valid_i,
    output logic load_mem_rsp_ready_o,
    input  logic [LOAD_BUS_ID_WIDTH-1:0] load_mem_rsp_id_i,
    input  logic [LOAD_DATA_WIDTH-1:0] load_mem_rsp_data_i,
    output logic store_mem_wr_valid_o,
    input  logic store_mem_wr_ready_i,
    output logic [ADDR_WIDTH-1:0] store_mem_wr_addr_o,
    output logic [STORE_MEM_DATA_WIDTH-1:0] store_mem_wr_data_o,
    output logic cmd_done_valid_o
);

    top_new_static #(
        .SA_WIDTH(SA_WIDTH), .SUBTILE_M(SUBTILE_M), .SUBTILE_N(SUBTILE_N),
        .SUBTILE_K(SUBTILE_K), .LANE_NUM(LANE_NUM),
        .ABUF_SIZE(ABUF_SIZE), .BBUF_SIZE(BBUF_SIZE), .PACC_NUM(PACC_NUM),
        .ADDR_WIDTH(ADDR_WIDTH), .DIM_WIDTH(DIM_WIDTH),
        .STORE_ROWS_PER_CYCLE(STORE_ROWS_PER_CYCLE), .LOAD_DATA_WIDTH(LOAD_DATA_WIDTH),
        .COUNT_WIDTH(16), .GEMM_INSTID_WIDTH(GEMM_INSTID_WIDTH)
    ) impl (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid_i(cmd_valid_i), .cmd_ready_o(cmd_ready_o),
        .cmd_a_base_i(cmd_a_base_i), .cmd_b_base_i(cmd_b_base_i),
        .cmd_c_base_i(cmd_c_base_i), .cmd_m_i(cmd_m_i),
        .cmd_n_i(cmd_n_i), .cmd_k_i(cmd_k_i), .cmd_batch_i(cmd_batch_i),
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
        .store_mem_wr_data_o(store_mem_wr_data_o),
        .cmd_done_valid_o(cmd_done_valid_o)
    );

endmodule

`default_nettype wire
