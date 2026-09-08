`default_nettype none

// Standalone load unit for the widest square static configuration.  Packed
// write-data ports are wiring-only views of the RTL's unpacked bank arrays.
module LoadUnit_M64_N64_K32_AB32_D1024 (
    input  logic clk,
    input  logic rst_n,
    input  logic uop_valid_i,
    output logic uop_ready_o,
    input  logic uop_is_b_i,
    input  logic [31:0] uop_addr_i,
    input  logic [4:0] uop_abufidx_i,
    input  logic [4:0] uop_bbufidx_i,
    input  logic [6:0] uop_valid_rows_i,
    output logic mem_req_valid_o,
    input  logic mem_req_ready_i,
    output logic [31:0] mem_req_addr_o,
    output logic [5:0] mem_req_id_o,
    input  logic mem_rsp_valid_i,
    output logic mem_rsp_ready_o,
    input  logic [5:0] mem_rsp_id_i,
    input  logic [1023:0] mem_rsp_data_i,
    output logic abuf_wr_valid_o,
    output logic [4:0] abuf_wr_idx_o,
    output logic [63:0] abuf_wr_bank_en_o,
    output logic [16383:0] abuf_wr_data_o,
    output logic bbuf_wr_valid_o,
    output logic [4:0] bbuf_wr_idx_o,
    output logic [63:0] bbuf_wr_bank_en_o,
    output logic [16383:0] bbuf_wr_data_o,
    output logic abuf_ready_valid_o,
    output logic [4:0] abuf_ready_idx_o,
    output logic bbuf_ready_valid_o,
    output logic [4:0] bbuf_ready_idx_o
);

    logic [255:0] abuf_wr_data [64];
    logic [255:0] bbuf_wr_data [64];

    for (genvar row = 0; row < 64; row++) begin : gen_pack
        assign abuf_wr_data_o[row*256 +: 256] = abuf_wr_data[row];
        assign bbuf_wr_data_o[row*256 +: 256] = bbuf_wr_data[row];
    end

    loadunit #(
        .SA_WIDTH(64),
        .SUBTILE_M(64),
        .SUBTILE_N(64),
        .SUBTILE_K(32),
        .ABUF_SIZE(32),
        .BBUF_SIZE(32),
        .ADDR_WIDTH(32),
        .ABUF_IDX_WIDTH(5),
        .BBUF_IDX_WIDTH(5),
        .ROW_IDX_WIDTH(6),
        .ROW_DATA_WIDTH(256),
        .LOAD_DATA_WIDTH(1024),
        .BUS_ID_WIDTH(6),
        .OUTSTANDING_NUM(64),
        .UOP_QUEUE_DEPTH(64),
        .ROWS_LEFT_WIDTH(7)
    ) impl (
        .abuf_wr_data_o(abuf_wr_data),
        .bbuf_wr_data_o(bbuf_wr_data),
        .*
    );

endmodule

`default_nettype wire
