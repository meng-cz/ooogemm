`default_nettype none

// Fixed L4W32 SA-only synthesis top, shared by static/dynamic experiments.
// M=N=32, K=32, lanes=4, PACC depth/PE=32 (32768 scalars total).
// Includes SA lane ping-pong buffers, allocation/start arbitration, skew,
// PE/PACC, and GETACC row scanning/reduction; no external command frontend,
// LOAD/STORE unit, or external A/B operand buffer is instantiated.
// Each packed input row occupies 256 bits; row/column 0 is in the low bits.
// ain_data_i[row*256 + k*8 +: 8] is A[row][k].
// bin_data_i[col*256 + k*8 +: 8] is transposed B[k][col].
// These are wiring-only views of sa's whole-tile input arrays, with no
// additional pipeline stages. Allocate a GEMM lane before filling its A/B.
// GETACC returns 2 consecutive FP32 rows/cycle (2048 bits), low row first.
module L4W32 (
    input  logic clk,
    input  logic rst_n,
    input  logic ain_valid,
    input  logic [8191:0] ain_data_i,
    input  logic [1:0] ain_laneidx,
    input  logic bin_valid,
    input  logic [8191:0] bin_data_i,
    input  logic [1:0] bin_laneidx,
    input  logic gemm_valid,
    output logic gemm_ready,
    output logic [1:0] gemm_alloc_lane,
    input  logic [15:0] gemm_instid,
    input  logic [4:0] gemm_paccidx,
    input  logic gemm_accum,
    output logic gemm_finish,
    output logic [15:0] gemm_finish_instid,
    input  logic getacc_valid,
    output logic getacc_ready,
    input  logic [4:0] getacc_idx,
    output logic getacc_data_valid,
    output logic [2047:0] getacc_data
);

    logic [255:0] ain_data [32];
    logic [255:0] bin_data [32];

    for (genvar row = 0; row < 32; row++) begin : gen_unpack
        assign ain_data[row] = ain_data_i[row*256 +: 256];
        assign bin_data[row] = bin_data_i[row*256 +: 256];
    end

    sa #(
        .SA_WIDTH(32),
        .SUBTILE_M(32),
        .SUBTILE_N(32),
        .SUBTILE_K(32),
        .LANE_NUM(4),
        .LANE_IDX_WIDTH(2),
        .PACC_NUM(32),
        .PACC_IDX_WIDTH(5),
        .PACC_EXP_WIDTH(10),
        .PACC_SIG_WIDTH(40),
        .FDOT_ACC_WIDTH(96),
        .FDOT_ACC_FRAC_BITS(18),
        .FDOT_CSA_WIDTH(98),
        .GEMM_INSTID_WIDTH(16),
        .K_IDX_WIDTH(5),
        .GETACC_ROWS_PER_CYCLE(2),
        .GETACC_GROUPS_PER_TILE(16),
        .GETACC_GROUP_IDX_WIDTH(4)
    ) impl (
        .clk(clk),
        .rst_n(rst_n),
        .ain_valid(ain_valid),
        .ain_data(ain_data),
        .ain_laneidx(ain_laneidx),
        .bin_valid(bin_valid),
        .bin_data(bin_data),
        .bin_laneidx(bin_laneidx),
        .gemm_valid(gemm_valid),
        .gemm_ready(gemm_ready),
        .gemm_alloc_lane(gemm_alloc_lane),
        .gemm_instid(gemm_instid),
        .gemm_paccidx(gemm_paccidx),
        .gemm_accum(gemm_accum),
        .gemm_finish(gemm_finish),
        .gemm_finish_instid(gemm_finish_instid),
        .getacc_valid(getacc_valid),
        .getacc_ready(getacc_ready),
        .getacc_idx(getacc_idx),
        .getacc_data_valid(getacc_data_valid),
        .getacc_data(getacc_data)
    );

endmodule

`default_nettype wire
