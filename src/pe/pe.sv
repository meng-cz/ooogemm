// Systolic-array processing element.
//
// Each physical GEMM lane has one fdot8e4m3. Left-side inputs are registered
// for one cycle, forwarded to the right, and used by the lane fdot in the same
// registered cycle. Top-side b inputs are registered for one cycle and
// forwarded downward.
//
// fdot outputs are aggregated into the single-write-port paccreg by bitwise OR
// after valid masking.  The reduce result is registered before paccreg so the
// multi-lane OR tree is isolated from both fdot and paccreg pipelines.  The
// external schedule must guarantee at most one fdot output is valid in any
// cycle, and must not submit the same paccidx again within the next three
// cycles (the earliest legal repeat is four submission cycles later).

`default_nettype none

module pe #(
    parameter int GEMM_LANE_NUM  = 4,
    parameter int PACC_NUM       = 16,
    parameter int PACC_IDX_WIDTH = (PACC_NUM <= 1) ? 1 : $clog2(PACC_NUM),
    parameter int PACC_EXP_WIDTH = 10,
    parameter int PACC_SIG_WIDTH = 40,
    parameter int FDOT_ACC_WIDTH = 96,
    parameter int FDOT_ACC_FRAC_BITS = 18,
    parameter int FDOT_CSA_WIDTH = FDOT_ACC_WIDTH + 2
) (
    input  logic clk,
    input  logic rst_n,

    input  logic left_valid_i [GEMM_LANE_NUM],
    input  logic [7:0] left_a_i [GEMM_LANE_NUM],
    input  logic left_first_i [GEMM_LANE_NUM],
    input  logic left_last_i [GEMM_LANE_NUM],
    input  logic [PACC_IDX_WIDTH-1:0] left_paccidx_i [GEMM_LANE_NUM],
    input  logic left_accum_i [GEMM_LANE_NUM],

    output logic right_valid_o [GEMM_LANE_NUM],
    output logic [7:0] right_a_o [GEMM_LANE_NUM],
    output logic right_first_o [GEMM_LANE_NUM],
    output logic right_last_o [GEMM_LANE_NUM],
    output logic [PACC_IDX_WIDTH-1:0] right_paccidx_o [GEMM_LANE_NUM],
    output logic right_accum_o [GEMM_LANE_NUM],

    input  logic [7:0] top_b_i [GEMM_LANE_NUM],
    output logic [7:0] bottom_b_o [GEMM_LANE_NUM],

    input  logic getacc_i,
    input  logic [PACC_IDX_WIDTH-1:0] getacc_idx_i,
    output logic getacc_o,
    output logic [31:0] getacc_data_o
);

    initial begin
        if (GEMM_LANE_NUM <= 0) begin
            $error("GEMM_LANE_NUM must be positive");
        end
        if (PACC_NUM <= 0) begin
            $error("PACC_NUM must be positive");
        end
    end

    logic left_valid_q [GEMM_LANE_NUM];
    logic [7:0] left_a_q [GEMM_LANE_NUM];
    logic left_first_q [GEMM_LANE_NUM];
    logic left_last_q [GEMM_LANE_NUM];
    logic [PACC_IDX_WIDTH-1:0] left_paccidx_q [GEMM_LANE_NUM];
    logic left_accum_q [GEMM_LANE_NUM];
    logic [7:0] top_b_q [GEMM_LANE_NUM];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int lane = 0; lane < GEMM_LANE_NUM; lane++) begin
                left_valid_q[lane]  <= 1'b0;
                left_a_q[lane]      <= 8'd0;
                left_first_q[lane]  <= 1'b0;
                left_last_q[lane]   <= 1'b0;
                left_paccidx_q[lane] <= '0;
                left_accum_q[lane]  <= 1'b0;
                top_b_q[lane]       <= 8'd0;
            end
        end else begin
            for (int lane = 0; lane < GEMM_LANE_NUM; lane++) begin
                left_valid_q[lane]   <= left_valid_i[lane];
                left_a_q[lane]       <= left_a_i[lane];
                left_first_q[lane]   <= left_first_i[lane];
                left_last_q[lane]    <= left_last_i[lane];
                left_paccidx_q[lane] <= left_paccidx_i[lane];
                left_accum_q[lane]   <= left_accum_i[lane];
                top_b_q[lane]        <= top_b_i[lane];
            end
        end
    end

    genvar out_lane;
    generate
        for (out_lane = 0; out_lane < GEMM_LANE_NUM; out_lane++) begin : gen_forward
            assign right_valid_o[out_lane]   = left_valid_q[out_lane];
            assign right_a_o[out_lane]       = left_a_q[out_lane];
            assign right_first_o[out_lane]   = left_first_q[out_lane];
            assign right_last_o[out_lane]    = left_last_q[out_lane];
            assign right_paccidx_o[out_lane] = left_paccidx_q[out_lane];
            assign right_accum_o[out_lane]   = left_accum_q[out_lane];
            assign bottom_b_o[out_lane]      = top_b_q[out_lane];
        end
    endgenerate

    logic fdot_valid [GEMM_LANE_NUM];
    logic signed [FDOT_CSA_WIDTH-1:0] fdot_sum [GEMM_LANE_NUM];
    logic signed [FDOT_CSA_WIDTH-1:0] fdot_carry [GEMM_LANE_NUM];
    logic fdot_nan [GEMM_LANE_NUM];
    logic [PACC_IDX_WIDTH-1:0] fdot_paccidx [GEMM_LANE_NUM];
    logic fdot_accum [GEMM_LANE_NUM];

    genvar lane;
    generate
        for (lane = 0; lane < GEMM_LANE_NUM; lane++) begin : gen_fdot
            fdot8e4m3 #(
                .ACC_WIDTH(FDOT_ACC_WIDTH),
                .ACC_FRAC_BITS(FDOT_ACC_FRAC_BITS),
                .FDOT_CSA_WIDTH(FDOT_CSA_WIDTH),
                .PACC_IDX_WIDTH(PACC_IDX_WIDTH)
            ) u_fdot8e4m3 (
                .clk(clk),
                .rst_n(rst_n),
                .valid_i(left_valid_q[lane]),
                .a_i(left_a_q[lane]),
                .b_i(top_b_q[lane]),
                .first_i(left_first_q[lane]),
                .last_i(left_last_q[lane]),
                .paccidx_i(left_paccidx_q[lane]),
                .accum_i(left_accum_q[lane]),
                .valid_o(fdot_valid[lane]),
                .psum_sum_o(fdot_sum[lane]),
                .psum_carry_o(fdot_carry[lane]),
                .psum_nan_o(fdot_nan[lane]),
                .paccidx_o(fdot_paccidx[lane]),
                .accum_o(fdot_accum[lane])
            );
        end
    endgenerate

    logic paccreg_valid_comb;
    logic signed [FDOT_CSA_WIDTH-1:0] paccreg_sum_comb;
    logic signed [FDOT_CSA_WIDTH-1:0] paccreg_carry_comb;
    logic paccreg_nan_comb;
    logic [PACC_IDX_WIDTH-1:0] paccreg_paccidx_comb;
    logic paccreg_accum_comb;

    logic paccreg_valid_q;
    logic signed [FDOT_CSA_WIDTH-1:0] paccreg_sum_q;
    logic signed [FDOT_CSA_WIDTH-1:0] paccreg_carry_q;
    logic paccreg_nan_q;
    logic [PACC_IDX_WIDTH-1:0] paccreg_paccidx_q;
    logic paccreg_accum_q;

    always_comb begin
        paccreg_valid_comb   = 1'b0;
        paccreg_sum_comb     = '0;
        paccreg_carry_comb   = '0;
        paccreg_nan_comb     = 1'b0;
        paccreg_paccidx_comb = '0;
        paccreg_accum_comb   = 1'b0;

        for (int lane_idx = 0; lane_idx < GEMM_LANE_NUM; lane_idx++) begin
            paccreg_valid_comb   |= fdot_valid[lane_idx];
            paccreg_sum_comb     |= fdot_sum[lane_idx] &
                {FDOT_CSA_WIDTH{fdot_valid[lane_idx]}};
            paccreg_carry_comb   |= fdot_carry[lane_idx] &
                {FDOT_CSA_WIDTH{fdot_valid[lane_idx]}};
            paccreg_nan_comb     |= fdot_nan[lane_idx] & fdot_valid[lane_idx];
            paccreg_paccidx_comb |= fdot_paccidx[lane_idx] &
                {PACC_IDX_WIDTH{fdot_valid[lane_idx]}};
            paccreg_accum_comb   |= fdot_accum[lane_idx] & fdot_valid[lane_idx];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            paccreg_valid_q   <= 1'b0;
            paccreg_sum_q     <= '0;
            paccreg_carry_q   <= '0;
            paccreg_nan_q     <= 1'b0;
            paccreg_paccidx_q <= '0;
            paccreg_accum_q   <= 1'b0;
        end else begin
            paccreg_valid_q   <= paccreg_valid_comb;
            paccreg_sum_q     <= paccreg_sum_comb;
            paccreg_carry_q   <= paccreg_carry_comb;
            paccreg_nan_q     <= paccreg_nan_comb;
            paccreg_paccidx_q <= paccreg_paccidx_comb;
            paccreg_accum_q   <= paccreg_accum_comb;
        end
    end

    paccreg #(
        .PACC_NUM(PACC_NUM),
        .PACC_IDX_WIDTH(PACC_IDX_WIDTH),
        .PACC_EXP_WIDTH(PACC_EXP_WIDTH),
        .PACC_SIG_WIDTH(PACC_SIG_WIDTH),
        .FDOT_ACC_WIDTH(FDOT_ACC_WIDTH),
        .FDOT_ACC_FRAC_BITS(FDOT_ACC_FRAC_BITS),
        .FDOT_CSA_WIDTH(FDOT_CSA_WIDTH)
    ) u_paccreg (
        .clk(clk),
        .rst_n(rst_n),
        .valid_i(paccreg_valid_q),
        .psum_sum_i(paccreg_sum_q),
        .psum_carry_i(paccreg_carry_q),
        .psum_nan_i(paccreg_nan_q),
        .paccidx_i(paccreg_paccidx_q),
        .accum_i(paccreg_accum_q),
        .getacc_i(getacc_i),
        .getacc_idx_i(getacc_idx_i),
        .getacc_o(getacc_o),
        .getacc_data_o(getacc_data_o)
    );

endmodule

`default_nettype wire
