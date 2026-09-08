`default_nettype none

// Standalone store unit matching the L4 M32xN32 experiment interface.
module StoreUnit_M32_N32_ACC128_R2 (
    input  logic clk,
    input  logic rst_n,
    input  logic uop_valid_i,
    output logic uop_ready_o,
    input  logic [31:0] uop_addr_i,
    input  logic [6:0] uop_paccidx_i,
    output logic sa_getacc_valid_o,
    input  logic sa_getacc_ready_i,
    output logic [6:0] sa_getacc_idx_o,
    input  logic sa_getacc_data_valid_i,
    input  logic [2047:0] sa_getacc_data_i,
    output logic mem_wr_valid_o,
    input  logic mem_wr_ready_i,
    output logic [31:0] mem_wr_addr_o,
    output logic [2047:0] mem_wr_data_o,
    output logic done_valid_o
);

    storeunit #(
        .SA_WIDTH(32),
        .SUBTILE_M(32),
        .SUBTILE_N(32),
        .PACC_NUM(128),
        .ADDR_WIDTH(32),
        .PACC_IDX_WIDTH(7),
        .ROW_DATA_WIDTH(1024),
        .ROWS_PER_CYCLE(2),
        .GROUPS_PER_TILE(16),
        .GROUP_IDX_WIDTH(4),
        .SA_DATA_WIDTH(2048),
        .MEM_DATA_WIDTH(2048),
        .FIFO_DEPTH(32),
        .FIFO_IDX_WIDTH(5),
        .FIFO_CNT_WIDTH(6),
        .UOP_FIFO_DEPTH(128),
        .UOP_FIFO_IDX_WIDTH(7),
        .UOP_FIFO_CNT_WIDTH(8)
    ) impl (.*);

endmodule

`default_nettype wire
