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
// constants use a single round-up reciprocal:
//
//   ceil(a / d) = floor((a + d - 1) * ceil(2^S / d) / 2^S)
//
// which is exact for every a < 2^WIDTH when S >= WIDTH + 1 + ceil(log2(d))
// (the classic Granlund-Montgomery bound).  Compared with the former
// estimate/correct/re-scale chain this removes one multiplier, two
// comparisons and two subtractions from every candidate's logic cone.
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
            localparam int RECIP_SHIFT = WIDTH + 1 + $clog2(DENOM);
            localparam logic [RECIP_SHIFT:0] RECIP_NUMERATOR =
                {1'b1, {RECIP_SHIFT{1'b0}}};
            localparam logic [RECIP_SHIFT-1:0] RECIPROCAL =
                RECIP_SHIFT'(
                    (RECIP_NUMERATOR + (RECIP_SHIFT + 1)'(DENOM - 1)) /
                    (RECIP_SHIFT + 1)'(DENOM));
            logic [WIDTH:0] numerator_biased;
            logic [WIDTH+RECIP_SHIFT:0] reciprocal_product;

            assign numerator_biased =
                {1'b0, numerator_i} + (WIDTH + 1)'(DENOM - 1);
            assign reciprocal_product = numerator_biased * RECIPROCAL;
            assign quotient_o = WIDTH'(reciprocal_product >> RECIP_SHIFT);
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
    parameter int TILE_COUNT_WIDTH = DIM_WIDTH -
        (($clog2(SUBTILE_M) < $clog2(SUBTILE_N)) ?
         $clog2(SUBTILE_M) : $clog2(SUBTILE_N)) + 1,
    parameter int COST_WIDTH       = (2 * TILE_COUNT_WIDTH) + 1
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
    // The scan pointer only ever walks 1..LOGIC_ABUF_SIZE, so it is kept in a
    // narrow register: a 13 bit index would make the candidate-table decoder
    // compare 13 bit values against 25 constants.
    localparam int SCAN_IDX_WIDTH =
        $clog2(LOGIC_ABUF_SIZE + UNROLL_NUM + 1);
    logic [BLOCK_M_WIDTH-1:0] amax_idx_q;
    logic [SCAN_IDX_WIDTH-1:0] scan_idx_q;
    logic best_valid_q;

    logic [BLOCK_M_WIDTH-1:0] best_bm_q;
    logic [BLOCK_N_WIDTH-1:0] best_bn_q;
    cost_t best_cost_q;
    logic [AREA_WIDTH-1:0] best_area_q;
    logic [BALANCE_WIDTH-1:0] best_balance_q;

    logic [BLOCK_M_WIDTH-1:0] best_bm_next;
    logic [BLOCK_N_WIDTH-1:0] best_bn_next;
    cost_t best_cost_next;
    logic best_valid_next;
    logic [AREA_WIDTH-1:0] best_area_next;
    logic [BALANCE_WIDTH-1:0] best_balance_next;
    logic scan_last;

    localparam int COST_HALF = (COST_WIDTH + 1) / 2;
    localparam int SUBTILE_M_SHIFT = $clog2(SUBTILE_M);
    localparam int SUBTILE_N_SHIFT = $clog2(SUBTILE_N);
    // Area and balance are BM-by-BN resource products, so they only need the
    // bits of the buffer sizes instead of the full cost width.  Narrowing them
    // shortens the tie-break comparators in the scan cycle.
    localparam int AREA_WIDTH =
        $clog2((LOGIC_ABUF_SIZE * LOGIC_BBUF_SIZE) + 1);
    localparam int BALANCE_WIDTH =
        $clog2(((LOGIC_ABUF_SIZE > LOGIC_BBUF_SIZE) ? LOGIC_ABUF_SIZE :
                LOGIC_BBUF_SIZE) + 1);

    function automatic tile_count_t ceil_m_tiles(
        input logic [DIM_WIDTH-1:0] value
    );
        begin
            return tile_count_t'(value >> SUBTILE_M_SHIFT) +
                   tile_count_t'((value & DIM_WIDTH'(SUBTILE_M - 1)) != '0);
        end
    endfunction

    function automatic tile_count_t ceil_n_tiles(
        input logic [DIM_WIDTH-1:0] value
    );
        begin
            return tile_count_t'(value >> SUBTILE_N_SHIFT) +
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

    // BM is a scan register whose legal range is a compile-time resource
    // bound, so every candidate's shape and cost depend on the accepted
    // command alone.  The whole table is therefore evaluated once from the
    // command payload, during the ST_IDLE cycle that accepts it, and the scan
    // cycles that follow only compare registered candidates.  This keeps the
    // constant dividers, the cost products and the final sum out of the
    // scan-cycle cone without adding an FSM state or an extra cycle.
    tile_count_t cmd_tm_comb, cmd_tn_comb;
    logic [BLOCK_N_WIDTH-1:0] candidate_bn_comb [0:LOGIC_ABUF_SIZE];
    cost_t candidate_cost_comb [0:LOGIC_ABUF_SIZE];

    logic [BLOCK_N_WIDTH-1:0] candidate_bn_q [0:LOGIC_ABUF_SIZE];
    cost_t candidate_cost_q [0:LOGIC_ABUF_SIZE];

    always_comb begin
        cmd_tm_comb = ceil_m_tiles(cmd_m_i);
        cmd_tn_comb = ceil_n_tiles(cmd_n_i);
    end

    assign candidate_bn_comb[0] = '0;
    assign candidate_cost_comb[0] = '0;

    generate
        for (genvar bm_value = 1; bm_value <= LOGIC_ABUF_SIZE;
             bm_value++) begin : gen_candidate_cost
            localparam int ACC_BN_CAP = LOGIC_ACC_NUM / bm_value;
            localparam int BN_CAP =
                (ACC_BN_CAP < LOGIC_BBUF_SIZE) ? ACC_BN_CAP : LOGIC_BBUF_SIZE;

            if (BN_CAP > 0) begin : gen_legal_bm
                tile_count_t m_blocks;
                tile_count_t n_blocks;
                // Keep the two cost products at the natural 2*TILE_COUNT_WIDTH
                // width: writing the sum directly would extend both operands
                // to cost_t and infer a much wider multiplier.
                logic [(2 * TILE_COUNT_WIDTH)-1:0] m_side_cost;
                logic [(2 * TILE_COUNT_WIDTH)-1:0] n_side_cost;

                blocksel_const_ceil_div #(
                    .WIDTH(TILE_COUNT_WIDTH),
                    .DENOM(bm_value)
                ) m_block_count (
                    .numerator_i(cmd_tm_comb),
                    .quotient_o(m_blocks)
                );

                blocksel_const_ceil_div #(
                    .WIDTH(TILE_COUNT_WIDTH),
                    .DENOM(BN_CAP)
                ) n_block_count (
                    .numerator_i(cmd_tn_comb),
                    .quotient_o(n_blocks)
                );
                assign candidate_bn_comb[bm_value] =
                    (cmd_tn_comb < tile_count_t'(BN_CAP)) ?
                    BLOCK_N_WIDTH'(cmd_tn_comb) : BLOCK_N_WIDTH'(BN_CAP);
                assign n_side_cost = cmd_tm_comb * n_blocks;
                assign m_side_cost = cmd_tn_comb * m_blocks;
                assign candidate_cost_comb[bm_value] =
                    cost_t'(n_side_cost) + cost_t'(m_side_cost);
            end else begin : gen_illegal_bm
                assign candidate_bn_comb[bm_value] = '0;
                assign candidate_cost_comb[bm_value] = '0;
            end
        end
    endgenerate

    always_comb begin
        best_bm_next = best_bm_q;
        best_bn_next = best_bn_q;
        best_cost_next = best_cost_q;
        best_area_next = best_area_q;
        best_balance_next = best_balance_q;
        best_valid_next = best_valid_q;
        scan_last = 1'b0;

        // An empty result shape is not a valid GEMM workload, but retaining a
        // 1x1 fallback keeps the handshake well-defined for malformed input.
        if ((tm_q == '0) || (tn_q == '0)) begin
            best_bm_next = BLOCK_M_WIDTH'(1);
            best_bn_next = BLOCK_N_WIDTH'(1);
            best_cost_next = '0;
            best_area_next = AREA_WIDTH'(1);
            best_balance_next = '0;
            // Equivalent to the old "cost = 0" sentinel: no candidate can
            // beat it, so nothing is accepted unconditionally.
            best_valid_next = 1'b1;
        end

        for (int offset = 0; offset < UNROLL_NUM; offset++) begin
            logic [SCAN_IDX_WIDTH-1:0] candidate_idx;
            tile_count_t candidate_bm;
            logic [BLOCK_N_WIDTH-1:0] candidate_bn;
            cost_t candidate_cost_value;
            logic [AREA_WIDTH-1:0] candidate_area_value;
            logic [BALANCE_WIDTH-1:0] candidate_balance;
            // Cost values span COST_WIDTH bits; comparing them as one ripple
            // chain is the longest part of the scan cycle, so the comparison
            // is split into a high half and a low half that are evaluated in
            // parallel and then combined.
            logic cost_hi_lt, cost_hi_eq, cost_lo_lt, cost_lo_eq;
            logic cost_less, cost_equal;
            logic candidate_better;

            candidate_idx = scan_idx_q + SCAN_IDX_WIDTH'(offset);
            candidate_bm = tile_count_t'(candidate_idx);
            candidate_bn = '0;
            candidate_cost_value = '0;
            candidate_area_value = '0;
            candidate_balance = '0;
            candidate_better = 1'b0;
            cost_hi_lt = 1'b0; cost_hi_eq = 1'b0;
            cost_lo_lt = 1'b0; cost_lo_eq = 1'b0;
            cost_less = 1'b0;  cost_equal = 1'b0;
            if ((candidate_idx >= SCAN_IDX_WIDTH'(1)) &&
                (candidate_idx <= amax_idx_q)) begin
                candidate_bn = candidate_bn_q[int'(candidate_idx)];
                candidate_cost_value = candidate_cost_q[int'(candidate_idx)];
            end

            if (candidate_bn != '0) begin
                cost_hi_lt =
                    candidate_cost_value[COST_WIDTH-1:COST_HALF] <
                    best_cost_next[COST_WIDTH-1:COST_HALF];
                cost_hi_eq =
                    candidate_cost_value[COST_WIDTH-1:COST_HALF] ==
                    best_cost_next[COST_WIDTH-1:COST_HALF];
                cost_lo_lt =
                    candidate_cost_value[COST_HALF-1:0] <
                    best_cost_next[COST_HALF-1:0];
                cost_lo_eq =
                    candidate_cost_value[COST_HALF-1:0] ==
                    best_cost_next[COST_HALF-1:0];
                cost_less = cost_hi_lt | (cost_hi_eq & cost_lo_lt);
                cost_equal = cost_hi_eq & cost_lo_eq;

                candidate_area_value = AREA_WIDTH'(candidate_bm) *
                    AREA_WIDTH'(candidate_bn);
                candidate_balance =
                    (candidate_bm >= tile_count_t'(candidate_bn)) ?
                    BALANCE_WIDTH'(candidate_bm -
                                   tile_count_t'(candidate_bn)) :
                    BALANCE_WIDTH'(tile_count_t'(candidate_bn) -
                                   candidate_bm);
                // best_valid_q replaces the "cost == all ones" sentinel, so
                // the first candidate is still taken unconditionally without
                // a COST_WIDTH-wide equality comparison in the path.
                candidate_better =
                    !best_valid_q || cost_less ||
                    (cost_equal && (candidate_area_value > best_area_next)) ||
                    (cost_equal && (candidate_area_value == best_area_next) &&
                     (candidate_balance < best_balance_next));

                // Cost itself depends only on the cost comparison.  On an
                // equal-cost tie it is already the correct value, so keep the
                // area/balance tie-break chain out of best_cost_q's D cone.
                if (!best_valid_q || cost_less) begin
                    best_cost_next = candidate_cost_value;
                end
                if (candidate_better) begin
                    best_bm_next = BLOCK_M_WIDTH'(candidate_bm);
                    best_bn_next = BLOCK_N_WIDTH'(candidate_bn);
                    best_area_next = candidate_area_value;
                    best_balance_next = candidate_balance;
                    best_valid_next = 1'b1;
                end
            end
        end

        scan_last = (amax_idx_q == '0) ||
                    ((scan_idx_q + SCAN_IDX_WIDTH'(UNROLL_NUM)) > amax_idx_q);
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
            amax_idx_q <= '0;
            scan_idx_q <= '0;
            best_valid_q <= 1'b0;
            best_bm_q <= BLOCK_M_WIDTH'(1);
            best_bn_q <= BLOCK_N_WIDTH'(1);
            best_cost_q <= {COST_WIDTH{1'b1}};
            best_area_q <= AREA_WIDTH'(1);
            best_balance_q <= '0;
            for (int bm_idx = 0; bm_idx <= LOGIC_ABUF_SIZE; bm_idx++) begin
                candidate_bn_q[bm_idx] <= '0;
                candidate_cost_q[bm_idx] <= '0;
            end
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
                        amax_idx_q <= BLOCK_M_WIDTH'(
                            min_tile_count(ceil_m_tiles(cmd_m_i),
                                           LOGIC_ABUF_SIZE));
                        scan_idx_q <= SCAN_IDX_WIDTH'(1);
                        best_valid_q <= 1'b0;
                        best_bm_q <= BLOCK_M_WIDTH'(1);
                        best_bn_q <= BLOCK_N_WIDTH'(1);
                        best_cost_q <= {COST_WIDTH{1'b1}};
                        best_area_q <= AREA_WIDTH'(1);
                        best_balance_q <= '0;
                        // Lock in the candidate table for this command; the
                        // SCAN cycles only read registered entries.
                        for (int bm_idx = 0; bm_idx <= LOGIC_ABUF_SIZE;
                             bm_idx++) begin
                            candidate_bn_q[bm_idx] <= candidate_bn_comb[bm_idx];
                            candidate_cost_q[bm_idx] <=
                                candidate_cost_comb[bm_idx];
                        end
                        state_q <= ST_SCAN;
                    end
                end

                ST_SCAN: begin
                    best_bm_q <= best_bm_next;
                    best_bn_q <= best_bn_next;
                    best_cost_q <= best_cost_next;
                    best_area_q <= best_area_next;
                    best_balance_q <= best_balance_next;
                    best_valid_q <= best_valid_next;
                    if (scan_last) begin
                        state_q <= ST_OUTPUT;
                    end else begin
                        scan_idx_q <= scan_idx_q + SCAN_IDX_WIDTH'(UNROLL_NUM);
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
