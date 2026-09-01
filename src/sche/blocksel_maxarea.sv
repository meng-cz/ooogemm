// Static output-block selector.
//
// The resource limits are compile-time constants.  This module therefore
// avoids the run-time BM scan used by blocksel and presents the command and
// its selected block as a combinational valid-ready pass-through.

`default_nettype none

/* The clock/reset and SA_WIDTH are retained to keep the blocksel interface
 * compatible, although this implementation is purely combinational. */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
module blocksel_maxarea #(
    parameter int SA_WIDTH         = 32,
    parameter int SUBTILE_M        = SA_WIDTH,
    parameter int SUBTILE_N        = SA_WIDTH,
    parameter int LOGIC_ABUF_SIZE  = 12,
    parameter int LOGIC_BBUF_SIZE  = 12,
    parameter int LOGIC_ACC_NUM    = 16,
    parameter int ADDR_WIDTH       = 32,
    parameter int DIM_WIDTH        = 16,
    parameter int UNROLL_NUM       = 1,
    parameter int BLOCK_M_WIDTH    = (LOGIC_ABUF_SIZE <= 1) ? 1 : $clog2(LOGIC_ABUF_SIZE + 1),
    parameter int BLOCK_N_WIDTH    = (LOGIC_BBUF_SIZE <= 1) ? 1 : $clog2(LOGIC_BBUF_SIZE + 1),
    parameter int TILE_COUNT_WIDTH = DIM_WIDTH + 1,
    parameter int COST_WIDTH       = (2 * DIM_WIDTH) + 2
) (
    input  logic clk,
    input  logic rst_n,

    input  logic cmd_valid_i,
    output logic cmd_ready_o,
    input  logic [ADDR_WIDTH-1:0] cmd_a_base_i,
    input  logic [ADDR_WIDTH-1:0] cmd_b_base_i,
    input  logic [ADDR_WIDTH-1:0] cmd_c_base_i,
    input  logic [DIM_WIDTH-1:0]  cmd_m_i,
    input  logic [DIM_WIDTH-1:0]  cmd_n_i,
    input  logic [DIM_WIDTH-1:0]  cmd_k_i,
    input  logic [DIM_WIDTH-1:0]  cmd_batch_i,

    output logic gemm_valid_o,
    input  logic gemm_ready_i,
    output logic [ADDR_WIDTH-1:0] gemm_a_base_o,
    output logic [ADDR_WIDTH-1:0] gemm_b_base_o,
    output logic [ADDR_WIDTH-1:0] gemm_c_base_o,
    output logic [DIM_WIDTH-1:0]  gemm_m_o,
    output logic [DIM_WIDTH-1:0]  gemm_n_o,
    output logic [DIM_WIDTH-1:0]  gemm_k_o,
    output logic [DIM_WIDTH-1:0]  gemm_batch_o,
    output logic [BLOCK_M_WIDTH-1:0] block_m_o,
    output logic [BLOCK_N_WIDTH-1:0] block_n_o
);

    // For equal-area candidates, select the pair closest to square and then
    // the smaller BM.  The latter makes the result deterministic when BM/BN
    // can be swapped without changing the balance.
    function automatic int fixed_block_m();
        int bm;
        int bn;
        int area;
        int balance;
        int best_area;
        int best_balance;
        int best_bm;
        begin
            best_area = 0;
            best_balance = 32'h7fffffff;
            best_bm = 1;
            for (bm = 1; bm <= LOGIC_ABUF_SIZE; bm = bm + 1) begin
                bn = LOGIC_BBUF_SIZE;
                if ((LOGIC_ACC_NUM / bm) < bn) begin
                    bn = LOGIC_ACC_NUM / bm;
                end
                if (bn >= 1) begin
                    area = bm * bn;
                    balance = (bm >= bn) ? (bm - bn) : (bn - bm);
                    if ((area > best_area) ||
                        ((area == best_area) && (balance < best_balance)) ||
                        ((area == best_area) && (balance == best_balance) &&
                         (bm < best_bm))) begin
                        best_area = area;
                        best_balance = balance;
                        best_bm = bm;
                    end
                end
            end
            return best_bm;
        end
    endfunction

    function automatic int fixed_block_n();
        int bm;
        int bn;
        int area;
        int balance;
        int best_area;
        int best_balance;
        int best_bm;
        int best_bn;
        begin
            best_area = 0;
            best_balance = 32'h7fffffff;
            best_bm = 1;
            best_bn = 1;
            for (bm = 1; bm <= LOGIC_ABUF_SIZE; bm = bm + 1) begin
                bn = LOGIC_BBUF_SIZE;
                if ((LOGIC_ACC_NUM / bm) < bn) begin
                    bn = LOGIC_ACC_NUM / bm;
                end
                if (bn >= 1) begin
                    area = bm * bn;
                    balance = (bm >= bn) ? (bm - bn) : (bn - bm);
                    if ((area > best_area) ||
                        ((area == best_area) && (balance < best_balance)) ||
                        ((area == best_area) && (balance == best_balance) &&
                         (bm < best_bm))) begin
                        best_area = area;
                        best_balance = balance;
                        best_bm = bm;
                        best_bn = bn;
                    end
                end
            end
            return best_bn;
        end
    endfunction

    localparam int FIXED_BLOCK_M = fixed_block_m();
    localparam int FIXED_BLOCK_N = fixed_block_n();

    function automatic logic [TILE_COUNT_WIDTH-1:0] ceil_m_tiles(
        input logic [DIM_WIDTH-1:0] value
    );
        logic [TILE_COUNT_WIDTH:0] extended;
        logic [TILE_COUNT_WIDTH-1:0] quotient;
        begin
            extended = {{(TILE_COUNT_WIDTH + 1 - DIM_WIDTH){1'b0}}, value};
            extended = extended + (TILE_COUNT_WIDTH + 1)'(SUBTILE_M - 1);
            quotient = TILE_COUNT_WIDTH'(
                extended / (TILE_COUNT_WIDTH + 1)'(SUBTILE_M));
            return quotient;
        end
    endfunction

    function automatic logic [TILE_COUNT_WIDTH-1:0] ceil_n_tiles(
        input logic [DIM_WIDTH-1:0] value
    );
        logic [TILE_COUNT_WIDTH:0] extended;
        logic [TILE_COUNT_WIDTH-1:0] quotient;
        begin
            extended = {{(TILE_COUNT_WIDTH + 1 - DIM_WIDTH){1'b0}}, value};
            extended = extended + (TILE_COUNT_WIDTH + 1)'(SUBTILE_N - 1);
            quotient = TILE_COUNT_WIDTH'(
                extended / (TILE_COUNT_WIDTH + 1)'(SUBTILE_N));
            return quotient;
        end
    endfunction

    logic [TILE_COUNT_WIDTH-1:0] tile_m;
    logic [TILE_COUNT_WIDTH-1:0] tile_n;

    assign cmd_ready_o = gemm_ready_i;
    assign gemm_valid_o = cmd_valid_i;

    assign gemm_a_base_o = cmd_a_base_i;
    assign gemm_b_base_o = cmd_b_base_i;
    assign gemm_c_base_o = cmd_c_base_i;
    assign gemm_m_o = cmd_m_i;
    assign gemm_n_o = cmd_n_i;
    assign gemm_k_o = cmd_k_i;
    assign gemm_batch_o = cmd_batch_i;

    always_comb begin
        tile_m = ceil_m_tiles(cmd_m_i);
        tile_n = ceil_n_tiles(cmd_n_i);

        block_m_o = BLOCK_M_WIDTH'(FIXED_BLOCK_M);
        block_n_o = BLOCK_N_WIDTH'(FIXED_BLOCK_N);
        if (tile_m < TILE_COUNT_WIDTH'(FIXED_BLOCK_M)) begin
            block_m_o = BLOCK_M_WIDTH'(tile_m);
        end
        if (tile_n < TILE_COUNT_WIDTH'(FIXED_BLOCK_N)) begin
            block_n_o = BLOCK_N_WIDTH'(tile_n);
        end
    end

    initial begin
        if (SUBTILE_M <= 0 || (SUBTILE_M & (SUBTILE_M - 1)) != 0 ||
            SUBTILE_N <= 0 || (SUBTILE_N & (SUBTILE_N - 1)) != 0) begin
            $error("SUBTILE_M and SUBTILE_N must be positive powers of two");
        end
        if (LOGIC_ABUF_SIZE <= 0 || LOGIC_BBUF_SIZE <= 0 ||
            LOGIC_ACC_NUM <= 0) begin
            $error("blocksel logical resources must be positive");
        end
        if (UNROLL_NUM <= 0) begin
            $error("UNROLL_NUM must be positive");
        end
        if (COST_WIDTH <= 0) begin
            $error("COST_WIDTH must be positive");
        end
        if (DIM_WIDTH <= 0) begin
            $error("DIM_WIDTH must be positive");
        end
    end

endmodule

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`default_nettype wire
