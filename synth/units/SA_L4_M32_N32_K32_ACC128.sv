`default_nettype none

// Standalone balanced SA configuration.  Matrix ports are flattened with
// wiring-only slices so physical timing remains attributable to sa/pe logic.
module SA_L4_M32_N32_K32_ACC128 (
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
    input  logic [6:0] gemm_paccidx,
    input  logic gemm_accum,
    output logic gemm_finish,
    output logic [15:0] gemm_finish_instid,
    input  logic getacc_valid,
    output logic getacc_ready,
    input  logic [6:0] getacc_idx,
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
        .PACC_NUM(128),
        .PACC_IDX_WIDTH(7),
        .PACC_EXP_WIDTH(10),
        .PACC_SIG_WIDTH(40),
        .FDOT_ACC_WIDTH(96),
        .FDOT_ACC_FRAC_BITS(18),
        .FDOT_CSA_WIDTH(98),
        .GEMM_INSTID_WIDTH(16),
        .GETACC_ROWS_PER_CYCLE(2),
        .GETACC_GROUPS_PER_TILE(16),
        .GETACC_GROUP_IDX_WIDTH(4)
    ) impl (
        .ain_data(ain_data),
        .bin_data(bin_data),
        .*
    );

endmodule

`default_nettype wire
