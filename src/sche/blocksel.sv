// Runtime output-block selector for a GEMM command.
//
// The selector evaluates BM in ascending order.  For each BM it derives the
// largest legal BN and estimates the number of A/B tile loads over the whole
// output plane:
//
//   cost = TM * ceil(TN / BN) + TN * ceil(TM / BM)
//
// UNROLL_NUM candidates are evaluated in parallel in each SCAN cycle.  A
// larger UNROLL_NUM reduces selection latency at the cost of a larger
// combinational candidate tree.  The selected block is returned together with
// the original command, unchanged.

`default_nettype none

// Exact unsigned ceil(numerator / DENOM) with a compile-time denominator.
// Power-of-two divisors reduce to wiring and a low-bit reduction.  Other
// constants use a fixed-point reciprocal; the estimate differs from floor by
// at most one, so one comparison/subtraction restores the exact quotient.
module blocksel_const_ceil_div #(
    parameter int WIDTH = 17,
    parameter int DENOM = 1
) (
    input  logic [WIDTH-1:0] numerator_i,
    output logic [WIDTH-1:0] quotient_o
);
    localparam bit DENOM_IS_POW2 =
        (DENOM > 0) && ((DENOM & (DENOM - 1)) == 0);
    localparam int DENOM_SHIFT = $clog2(DENOM);

    generate
        if (DENOM_IS_POW2) begin : gen_pow2
            assign quotient_o = (numerator_i >> DENOM_SHIFT) +
                WIDTH'((numerator_i & WIDTH'(DENOM - 1)) != '0);
        end else begin : gen_reciprocal
            localparam logic [WIDTH:0] RECIPROCAL =
                ({1'b1, {WIDTH{1'b0}}} + (WIDTH + 1)'(DENOM - 1)) /
                (WIDTH + 1)'(DENOM);
            logic [(2 * WIDTH):0] reciprocal_product;
            logic [WIDTH:0] quotient_estimate;
            logic [WIDTH:0] quotient_floor;
            logic [(2 * WIDTH)+1:0] estimate_scaled;
            logic [(2 * WIDTH)+1:0] floor_scaled;
            logic [(2 * WIDTH)+1:0] numerator_extended;

            assign reciprocal_product = numerator_i * RECIPROCAL;
            assign quotient_estimate =
                (WIDTH + 1)'(reciprocal_product >> WIDTH);
            assign estimate_scaled =
                quotient_estimate * (WIDTH + 1)'(DENOM);
            assign numerator_extended =
                {{(WIDTH + 2){1'b0}}, numerator_i};
            assign quotient_floor = (estimate_scaled > numerator_extended) ?
                (quotient_estimate - 1'b1) : quotient_estimate;
            assign floor_scaled = quotient_floor * (WIDTH + 1)'(DENOM);
            assign quotient_o = WIDTH'(quotient_floor) +
                WIDTH'(floor_scaled != numerator_extended);
        end
    endgenerate

    initial begin
        if (DENOM <= 0) begin
            $error("blocksel_const_ceil_div DENOM must be positive");
        end
    end
endmodule

module blocksel #(
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

    typedef logic [TILE_COUNT_WIDTH-1:0] tile_count_t;
    typedef logic [COST_WIDTH-1:0] cost_t;

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_SCAN,
        ST_OUTPUT
    } state_t;

    state_t state_q;

    logic [ADDR_WIDTH-1:0] cmd_a_base_q;
    logic [ADDR_WIDTH-1:0] cmd_b_base_q;
    logic [ADDR_WIDTH-1:0] cmd_c_base_q;
    logic [DIM_WIDTH-1:0] cmd_m_q;
    logic [DIM_WIDTH-1:0] cmd_n_q;
    logic [DIM_WIDTH-1:0] cmd_k_q;
    logic [DIM_WIDTH-1:0] cmd_batch_q;

    tile_count_t tm_q;
    tile_count_t tn_q;
    tile_count_t amax_q;
    tile_count_t scan_bm_q;

    logic [BLOCK_M_WIDTH-1:0] best_bm_q;
    logic [BLOCK_N_WIDTH-1:0] best_bn_q;
    cost_t best_cost_q;
    cost_t best_area_q;

    logic [BLOCK_M_WIDTH-1:0] best_bm_next;
    logic [BLOCK_N_WIDTH-1:0] best_bn_next;
    cost_t best_cost_next;
    cost_t best_area_next;
    logic scan_last;

    localparam int SUBTILE_M_SHIFT = $clog2(SUBTILE_M);
    localparam int SUBTILE_N_SHIFT = $clog2(SUBTILE_N);

    function automatic tile_count_t ceil_m_tiles(
        input logic [DIM_WIDTH-1:0] value
    );
        begin
            return (tile_count_t'(value) >> SUBTILE_M_SHIFT) +
                   tile_count_t'((value & DIM_WIDTH'(SUBTILE_M - 1)) != '0);
        end
    endfunction

    function automatic tile_count_t ceil_n_tiles(
        input logic [DIM_WIDTH-1:0] value
    );
        begin
            return (tile_count_t'(value) >> SUBTILE_N_SHIFT) +
                   tile_count_t'((value & DIM_WIDTH'(SUBTILE_N - 1)) != '0);
        end
    endfunction

    function automatic tile_count_t min_tile_count(
        input tile_count_t value,
        input int         limit
    );
        begin
            if (value > tile_count_t'(limit)) begin
                return tile_count_t'(limit);
            end
            return value;
        end
    endfunction

    // BM is a scan register, but its legal range is a compile-time resource
    // bound.  Generate one constant-divisor cost entry for every possible BM
    // and select it by index.  This prevents a synthesizer from inferring the
    // much larger variable-divisor circuits implied by the original RTL.
    tile_count_t candidate_bn_by_bm [0:LOGIC_ABUF_SIZE];
    cost_t candidate_cost_by_bm [0:LOGIC_ABUF_SIZE];
    cost_t candidate_area_by_bm [0:LOGIC_ABUF_SIZE];

    assign candidate_bn_by_bm[0] = '0;
    assign candidate_cost_by_bm[0] = '0;
    assign candidate_area_by_bm[0] = '0;

    generate
        for (genvar bm_value = 1; bm_value <= LOGIC_ABUF_SIZE;
             bm_value++) begin : gen_candidate_cost
            localparam int ACC_BN_CAP = LOGIC_ACC_NUM / bm_value;
            localparam int BN_CAP =
                (ACC_BN_CAP < LOGIC_BBUF_SIZE) ? ACC_BN_CAP : LOGIC_BBUF_SIZE;

            if (BN_CAP > 0) begin : gen_legal_bm
                tile_count_t m_blocks;
                tile_count_t n_blocks;

                blocksel_const_ceil_div #(
                    .WIDTH(TILE_COUNT_WIDTH),
                    .DENOM(bm_value)
                ) m_block_count (
                    .numerator_i(tm_q),
                    .quotient_o(m_blocks)
                );

                blocksel_const_ceil_div #(
                    .WIDTH(TILE_COUNT_WIDTH),
                    .DENOM(BN_CAP)
                ) n_block_count (
                    .numerator_i(tn_q),
                    .quotient_o(n_blocks)
                );
                assign candidate_bn_by_bm[bm_value] =
                    (tn_q < tile_count_t'(BN_CAP)) ? tn_q :
                                                     tile_count_t'(BN_CAP);
                assign candidate_cost_by_bm[bm_value] =
                    cost_t'(tm_q) * cost_t'(n_blocks) +
                    cost_t'(tn_q) * cost_t'(m_blocks);
                assign candidate_area_by_bm[bm_value] =
                    cost_t'(bm_value) *
                    cost_t'(candidate_bn_by_bm[bm_value]);
            end else begin : gen_illegal_bm
                assign candidate_bn_by_bm[bm_value] = '0;
                assign candidate_cost_by_bm[bm_value] = '0;
                assign candidate_area_by_bm[bm_value] = '0;
            end
        end
    endgenerate

    always_comb begin
        best_bm_next = best_bm_q;
        best_bn_next = best_bn_q;
        best_cost_next = best_cost_q;
        best_area_next = best_area_q;
        scan_last = 1'b0;

        // An empty result shape is not a valid GEMM workload, but retaining a
        // 1x1 fallback keeps the handshake well-defined for malformed input.
        if ((tm_q == '0) || (tn_q == '0)) begin
            best_bm_next = BLOCK_M_WIDTH'(1);
            best_bn_next = BLOCK_N_WIDTH'(1);
            best_cost_next = '0;
            best_area_next = cost_t'(1);
        end

        for (int offset = 0; offset < UNROLL_NUM; offset++) begin
            tile_count_t candidate_bm;
            tile_count_t candidate_bn;
            cost_t candidate_cost_value;
            cost_t candidate_area_value;
            cost_t candidate_balance;
            cost_t best_balance;

            candidate_bm = scan_bm_q + tile_count_t'(offset);
            candidate_bn = '0;
            candidate_cost_value = '0;
            candidate_area_value = '0;
            candidate_balance = '0;
            best_balance = '0;
            if ((candidate_bm >= 1) && (candidate_bm <= amax_q)) begin
                candidate_bn = candidate_bn_by_bm[int'(candidate_bm)];
            end

            if (candidate_bn != '0) begin
                candidate_cost_value = candidate_cost_by_bm[int'(candidate_bm)];
                candidate_area_value = candidate_area_by_bm[int'(candidate_bm)];
                candidate_balance = (candidate_bm >= candidate_bn) ?
                    (cost_t'(candidate_bm) - cost_t'(candidate_bn)) :
                    (cost_t'(candidate_bn) - cost_t'(candidate_bm));
                best_balance = (cost_t'(best_bm_next) >= cost_t'(best_bn_next)) ?
                    (cost_t'(best_bm_next) - cost_t'(best_bn_next)) :
                    (cost_t'(best_bn_next) - cost_t'(best_bm_next));

                if ((best_cost_next == {COST_WIDTH{1'b1}}) ||
                    (candidate_cost_value < best_cost_next) ||
                    ((candidate_cost_value == best_cost_next) &&
                     (candidate_area_value > best_area_next)) ||
                    ((candidate_cost_value == best_cost_next) &&
                     (candidate_area_value == best_area_next) &&
                     (candidate_balance < best_balance))) begin
                    best_bm_next = BLOCK_M_WIDTH'(candidate_bm);
                    best_bn_next = BLOCK_N_WIDTH'(candidate_bn);
                    best_cost_next = candidate_cost_value;
                    best_area_next = candidate_area_value;
                end
            end
        end

        scan_last = (amax_q == '0) ||
                    ((scan_bm_q + tile_count_t'(UNROLL_NUM)) > amax_q);
    end

    assign cmd_ready_o = (state_q == ST_IDLE);
    assign gemm_valid_o = (state_q == ST_OUTPUT);
    assign gemm_a_base_o = cmd_a_base_q;
    assign gemm_b_base_o = cmd_b_base_q;
    assign gemm_c_base_o = cmd_c_base_q;
    assign gemm_m_o = cmd_m_q;
    assign gemm_n_o = cmd_n_q;
    assign gemm_k_o = cmd_k_q;
    assign gemm_batch_o = cmd_batch_q;
    assign block_m_o = best_bm_q;
    assign block_n_o = best_bn_q;

    wire cmd_fire = cmd_valid_i && cmd_ready_o;
    wire gemm_fire = gemm_valid_o && gemm_ready_i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= ST_IDLE;
            cmd_a_base_q <= '0;
            cmd_b_base_q <= '0;
            cmd_c_base_q <= '0;
            cmd_m_q <= '0;
            cmd_n_q <= '0;
            cmd_k_q <= '0;
            cmd_batch_q <= '0;
            tm_q <= '0;
            tn_q <= '0;
            amax_q <= '0;
            scan_bm_q <= '0;
            best_bm_q <= BLOCK_M_WIDTH'(1);
            best_bn_q <= BLOCK_N_WIDTH'(1);
            best_cost_q <= {COST_WIDTH{1'b1}};
            best_area_q <= cost_t'(1);
        end else begin
            unique case (state_q)
                ST_IDLE: begin
                    if (cmd_fire) begin
                        cmd_a_base_q <= cmd_a_base_i;
                        cmd_b_base_q <= cmd_b_base_i;
                        cmd_c_base_q <= cmd_c_base_i;
                        cmd_m_q <= cmd_m_i;
                        cmd_n_q <= cmd_n_i;
                        cmd_k_q <= cmd_k_i;
                        cmd_batch_q <= cmd_batch_i;
                        tm_q <= ceil_m_tiles(cmd_m_i);
                        tn_q <= ceil_n_tiles(cmd_n_i);
                        amax_q <= min_tile_count(ceil_m_tiles(cmd_m_i), LOGIC_ABUF_SIZE);
                        scan_bm_q <= tile_count_t'(1);
                        best_bm_q <= BLOCK_M_WIDTH'(1);
                        best_bn_q <= BLOCK_N_WIDTH'(1);
                        best_cost_q <= {COST_WIDTH{1'b1}};
                        best_area_q <= cost_t'(1);
                        state_q <= ST_SCAN;
                    end
                end

                ST_SCAN: begin
                    best_bm_q <= best_bm_next;
                    best_bn_q <= best_bn_next;
                    best_cost_q <= best_cost_next;
                    best_area_q <= best_area_next;
                    if (scan_last) begin
                        state_q <= ST_OUTPUT;
                    end else begin
                        scan_bm_q <= scan_bm_q + tile_count_t'(UNROLL_NUM);
                    end
                end

                ST_OUTPUT: begin
                    if (gemm_fire) begin
                        state_q <= ST_IDLE;
                    end
                end

                default: state_q <= ST_IDLE;
            endcase
        end
    end

    initial begin
        if (SUBTILE_M <= 0 || (SUBTILE_M & (SUBTILE_M - 1)) != 0 ||
            SUBTILE_N <= 0 || (SUBTILE_N & (SUBTILE_N - 1)) != 0) begin
            $error("SUBTILE_M and SUBTILE_N must be positive powers of two");
        end
        if ((LOGIC_ABUF_SIZE <= 0) || (LOGIC_BBUF_SIZE <= 0) ||
            (LOGIC_ACC_NUM <= 0)) begin
            $error("blocksel logical resources must be positive");
        end
        if (UNROLL_NUM <= 0) begin
            $error("UNROLL_NUM must be positive");
        end
        if (DIM_WIDTH <= 0) begin
            $error("DIM_WIDTH must be positive");
        end
    end

endmodule

`default_nettype wire
