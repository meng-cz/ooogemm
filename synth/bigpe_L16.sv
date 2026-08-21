`default_nettype none

module bigpe_L16 (
    input  logic clk,
    input  logic rst_n,

    input  logic [15:0] left_valid_i,
    input  logic [127:0] left_a_i,
    input  logic [15:0] left_first_i,
    input  logic [15:0] left_last_i,
    input  logic [63:0] left_paccidx_i,
    input  logic [15:0] left_accum_i,

    output logic [15:0] right_valid_o,
    output logic [127:0] right_a_o,
    output logic [15:0] right_first_o,
    output logic [15:0] right_last_o,
    output logic [63:0] right_paccidx_o,
    output logic [15:0] right_accum_o,

    input  logic [127:0] top_b_i,
    output logic [127:0] bottom_b_o,

    input  logic getacc_i,
    input  logic [3:0] getacc_idx_i,
    output logic getacc_o,
    output logic [31:0] getacc_data_o
);

    localparam int GEMM_LANE_NUM = 16;
    localparam int PACC_NUM = 16;
    localparam int PACC_IDX_WIDTH = 4;
    localparam int PACC_EXP_WIDTH = 10;
    localparam int PACC_SIG_WIDTH = 40;
    localparam int FDOT_ACC_WIDTH = 96;
    localparam int FDOT_ACC_FRAC_BITS = 18;

    logic left_valid [GEMM_LANE_NUM];
    logic [7:0] left_a [GEMM_LANE_NUM];
    logic left_first [GEMM_LANE_NUM];
    logic left_last [GEMM_LANE_NUM];
    logic [PACC_IDX_WIDTH-1:0] left_paccidx [GEMM_LANE_NUM];
    logic left_accum [GEMM_LANE_NUM];

    logic right_valid [GEMM_LANE_NUM];
    logic [7:0] right_a [GEMM_LANE_NUM];
    logic right_first [GEMM_LANE_NUM];
    logic right_last [GEMM_LANE_NUM];
    logic [PACC_IDX_WIDTH-1:0] right_paccidx [GEMM_LANE_NUM];
    logic right_accum [GEMM_LANE_NUM];

    logic [7:0] top_b [GEMM_LANE_NUM];
    logic [7:0] bottom_b [GEMM_LANE_NUM];

    genvar lane;
    generate
        for (lane = 0; lane < GEMM_LANE_NUM; lane++) begin : gen_port_pack
            assign left_valid[lane] = left_valid_i[lane];
            assign left_a[lane] = left_a_i[lane*8 +: 8];
            assign left_first[lane] = left_first_i[lane];
            assign left_last[lane] = left_last_i[lane];
            assign left_paccidx[lane] = left_paccidx_i[lane*PACC_IDX_WIDTH +: PACC_IDX_WIDTH];
            assign left_accum[lane] = left_accum_i[lane];
            assign top_b[lane] = top_b_i[lane*8 +: 8];

            assign right_valid_o[lane] = right_valid[lane];
            assign right_a_o[lane*8 +: 8] = right_a[lane];
            assign right_first_o[lane] = right_first[lane];
            assign right_last_o[lane] = right_last[lane];
            assign right_paccidx_o[lane*PACC_IDX_WIDTH +: PACC_IDX_WIDTH] = right_paccidx[lane];
            assign right_accum_o[lane] = right_accum[lane];
            assign bottom_b_o[lane*8 +: 8] = bottom_b[lane];
        end
    endgenerate

    pe #(
        .GEMM_LANE_NUM(GEMM_LANE_NUM),
        .PACC_NUM(PACC_NUM),
        .PACC_IDX_WIDTH(PACC_IDX_WIDTH),
        .PACC_EXP_WIDTH(PACC_EXP_WIDTH),
        .PACC_SIG_WIDTH(PACC_SIG_WIDTH),
        .FDOT_ACC_WIDTH(FDOT_ACC_WIDTH),
        .FDOT_ACC_FRAC_BITS(FDOT_ACC_FRAC_BITS)
    ) u_pe (
        .clk(clk),
        .rst_n(rst_n),
        .left_valid_i(left_valid),
        .left_a_i(left_a),
        .left_first_i(left_first),
        .left_last_i(left_last),
        .left_paccidx_i(left_paccidx),
        .left_accum_i(left_accum),
        .right_valid_o(right_valid),
        .right_a_o(right_a),
        .right_first_o(right_first),
        .right_last_o(right_last),
        .right_paccidx_o(right_paccidx),
        .right_accum_o(right_accum),
        .top_b_i(top_b),
        .bottom_b_o(bottom_b),
        .getacc_i(getacc_i),
        .getacc_idx_i(getacc_idx_i),
        .getacc_o(getacc_o),
        .getacc_data_o(getacc_data_o)
    );

endmodule

`default_nettype wire
