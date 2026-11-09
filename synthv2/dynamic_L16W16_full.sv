`default_nettype none

// Fixed L16W16 synthesis top; no parameter overrides are required or exposed.
// M=N=16, K=32, lanes=16; physical A/B/PACC=32/32/128.
// Logical A/B/PACC=16/16/64; PACC is the depth per PE.
// External A/B buffers total 32768 bytes (excluding SA lane buffers);
// the array has 32768 scalar PACC entries.
// Complete dynamic path: block selection, command/uop generation, renaming,
// out-of-order scheduling/dispatch, LOAD/STORE, operand buffers, and full SA.
// DO: 32 slots, 4 ACC entries/slot, 16 GEMMs/slot; LOAD FIFO depth 16.
// GEMM completion tracking depth 64; retain existing backend queue defaults.
// Memory interface: 32-bit tile/beat-linear addresses, 1024-bit LOAD,
// 2048-bit STORE (4 rows/cycle), with the existing valid/ready protocol.
// Ordinary synthesis/lint must leave OOOGEMM_ABLATION undefined.
module dynamic_L16W16_full (
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
    output logic [3:0] load_mem_req_id_o,
    input  logic load_mem_rsp_valid_i,
    output logic load_mem_rsp_ready_o,
    input  logic [3:0] load_mem_rsp_id_i,
    input  logic [1023:0] load_mem_rsp_data_i,
    output logic store_mem_wr_valid_o,
    input  logic store_mem_wr_ready_i,
    output logic [31:0] store_mem_wr_addr_o,
    output logic [2047:0] store_mem_wr_data_o
);

    top_dynamic #(
        .SA_WIDTH(16),
        .SUBTILE_M(16),
        .SUBTILE_N(16),
        .SUBTILE_K(32),
        .LANE_NUM(16),
        .ABUF_SIZE(32),
        .BBUF_SIZE(32),
        .PACC_NUM(128),
        .ADDR_WIDTH(32),
        .DIM_WIDTH(16),
        .STORE_ROWS_PER_CYCLE(4),
        .LOAD_DATA_WIDTH(1024),
        .LANE_IDX_WIDTH(4),
        .ABUF_IDX_WIDTH(5),
        .BBUF_IDX_WIDTH(5),
        .PACC_IDX_WIDTH(7),
        .ROW8_WIDTH(256),
        .MAX_SUBTILE_ROWS(16),
        .LOAD_BUS_ID_WIDTH(4),
        .ROW32_WIDTH(512),
        .LOAD_ROWS_WIDTH(5),
        .STORE_MEM_DATA_WIDTH(2048),
        .GEMM_INSTID_WIDTH(16),
        .BLOCKSEL_UNROLL_NUM(1),
        .BLOCK_M_WIDTH(5),
        .BLOCK_N_WIDTH(5),
        .ABUF_LOGIC_SIZE(16),
        .BBUF_LOGIC_SIZE(16),
        .PACC_LOGIC_SIZE(64),
        .GEMM_IN_ORDER(1'b0),
        .SCHED_SLOT_ACC_COUNT(4),
        .GEMM_TRACK_DEPTH(64),
        .GEMM_TRACK_IDX_WIDTH(6),
        .ABUF_LOGIC_IDX_WIDTH(4),
        .BBUF_LOGIC_IDX_WIDTH(4),
        .PACC_LOGIC_IDX_WIDTH(6)
    ) impl (
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
