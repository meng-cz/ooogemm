// Static GEMM uop parser with explicit double-buffer and PACC fence uops.
//
// Interface-compatible with uopparse.  It emits the same LOAD_A/LOAD_B/GEMM/
// OUTPUT uops, plus:
//   - UOP_BUF_SWAP: wait for write-side A/B loads and read-side GEMM consumers,
//     then swap ABuf/BBuf ping-pong read/write sides.
//   - UOP_ACC_FENCE: wait for all previously submitted asynchronous OUTPUT
//     uops to complete before subsequent GEMM uops reuse PACC.
//
// No additional payload is attached to these special uops.  LOAD/GEMM use the
// physical ABuf/BBuf slot index directly.  The two ping-pong groups are the low
// and high halves of each operand buffer; odd leftover entries are unused.
//
// Per output block, the first K-wave is loaded, swapped into read side, and
// then the next K-wave is loaded before the current K-wave GEMMs.  The first
// GEMM of each command is preceded by UOP_ACC_FENCE, but only after the
// command's leading LOAD/PREFETCH work has been emitted, so the next command's
// operand traffic can overlap prior asynchronous OUTPUT draining.  After a
// block's OUTPUT uops, the next block's first loads are emitted before
// UOP_ACC_FENCE so operand prefetch can similarly overlap output draining.
// Across command boundaries the initial operand buffer half alternates: the
// first K-wave of a new command uses the opposite half from the prior command's
// final GEMM wave.

`default_nettype none

module static_uopparse #(
    parameter int SA_WIDTH       = 4,
    parameter int ABUF_SIZE      = 8,
    parameter int BBUF_SIZE      = 8,
    parameter int PACC_NUM       = 16,
    parameter int ADDR_WIDTH     = 32,
    parameter int DIM_WIDTH      = 16,
    parameter int ABUF_IDX_WIDTH = (ABUF_SIZE <= 1) ? 1 : $clog2(ABUF_SIZE),
    parameter int BBUF_IDX_WIDTH = (BBUF_SIZE <= 1) ? 1 : $clog2(BBUF_SIZE),
    parameter int PACC_IDX_WIDTH = (PACC_NUM <= 1) ? 1 : $clog2(PACC_NUM),
    parameter int ABUF_GROUP_SIZE = ABUF_SIZE / 2,
    parameter int BBUF_GROUP_SIZE = BBUF_SIZE / 2,
    parameter int LOAD_ROWS_WIDTH = (SA_WIDTH <= 1) ? 1 : $clog2(SA_WIDTH + 1),
    parameter int BLOCK_M        = choose_block_m(ABUF_GROUP_SIZE, BBUF_GROUP_SIZE, PACC_NUM),
    parameter int BLOCK_N        = choose_block_n(ABUF_GROUP_SIZE, BBUF_GROUP_SIZE, PACC_NUM),
    parameter int TILE_COUNT_WIDTH = DIM_WIDTH + 1
) (
    input  logic clk,
    input  logic rst_n,

    input  logic cmd_valid_i,
    output logic cmd_ready_o,
    input  logic [ADDR_WIDTH-1:0] cmd_a_base_i,
    input  logic [ADDR_WIDTH-1:0] cmd_b_base_i,
    input  logic [ADDR_WIDTH-1:0] cmd_c_base_i,
    input  logic [DIM_WIDTH-1:0] cmd_m_i,
    input  logic [DIM_WIDTH-1:0] cmd_n_i,
    input  logic [DIM_WIDTH-1:0] cmd_k_i,

    output logic uop_valid_o,
    input  logic uop_ready_i,
    output uopparse_pkg::uop_type_e uop_type_o,
    output logic [ADDR_WIDTH-1:0] uop_addr_o,
    output logic [ABUF_IDX_WIDTH-1:0] uop_abufidx_o,
    output logic [BBUF_IDX_WIDTH-1:0] uop_bbufidx_o,
    output logic [PACC_IDX_WIDTH-1:0] uop_paccidx_o,
    output logic [LOAD_ROWS_WIDTH-1:0] uop_valid_rows_o,
    output logic uop_accum_o
);

    import uopparse_pkg::*;

    function automatic int choose_block_m(
        input int abuf_group_size,
        input int bbuf_group_size,
        input int pacc_num
    );
        int best_m;
        int best_n;
        int best_area;
        int best_balance;
        int area;
        int balance;
        begin
            best_m = 1;
            best_n = 1;
            best_area = 1;
            best_balance = 0;
            for (int bm = 1; bm <= abuf_group_size; bm++) begin
                for (int bn = 1; bn <= bbuf_group_size; bn++) begin
                    area = bm * bn;
                    balance = (bm >= bn) ? (bm - bn) : (bn - bm);
                    if ((area <= pacc_num) &&
                        ((area > best_area) ||
                         ((area == best_area) && (balance < best_balance)) ||
                         ((area == best_area) && (balance == best_balance) && (bm > best_m)) ||
                         ((area == best_area) && (balance == best_balance) && (bm == best_m) &&
                          (bn > best_n)))) begin
                        best_m = bm;
                        best_n = bn;
                        best_area = area;
                        best_balance = balance;
                    end
                end
            end
            return best_m;
        end
    endfunction

    function automatic int choose_block_n(
        input int abuf_group_size,
        input int bbuf_group_size,
        input int pacc_num
    );
        int best_m;
        int best_n;
        int best_area;
        int best_balance;
        int area;
        int balance;
        begin
            best_m = 1;
            best_n = 1;
            best_area = 1;
            best_balance = 0;
            for (int bm = 1; bm <= abuf_group_size; bm++) begin
                for (int bn = 1; bn <= bbuf_group_size; bn++) begin
                    area = bm * bn;
                    balance = (bm >= bn) ? (bm - bn) : (bn - bm);
                    if ((area <= pacc_num) &&
                        ((area > best_area) ||
                         ((area == best_area) && (balance < best_balance)) ||
                         ((area == best_area) && (balance == best_balance) && (bm > best_m)) ||
                         ((area == best_area) && (balance == best_balance) && (bm == best_m) &&
                          (bn > best_n)))) begin
                        best_m = bm;
                        best_n = bn;
                        best_area = area;
                        best_balance = balance;
                    end
                end
            end
            return best_n;
        end
    endfunction

    initial begin
        if (SA_WIDTH <= 0) begin
            $error("SA_WIDTH must be positive");
        end
        if (ABUF_SIZE < 2) begin
            $error("ABUF_SIZE must be at least two for ping-pong buffering");
        end
        if (BBUF_SIZE < 2) begin
            $error("BBUF_SIZE must be at least two for ping-pong buffering");
        end
        if (PACC_NUM <= 0) begin
            $error("PACC_NUM must be positive");
        end
        if ((BLOCK_M <= 0) || (BLOCK_M > ABUF_GROUP_SIZE)) begin
            $error("BLOCK_M must fit one ABuf ping-pong group");
        end
        if ((BLOCK_N <= 0) || (BLOCK_N > BBUF_GROUP_SIZE)) begin
            $error("BLOCK_N must fit one BBuf ping-pong group");
        end
        if ((BLOCK_M * BLOCK_N) > PACC_NUM) begin
            $error("BLOCK_M * BLOCK_N must not exceed PACC_NUM");
        end
    end

    typedef logic [TILE_COUNT_WIDTH-1:0] tile_count_t;
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_LOAD_A,
        ST_LOAD_B,
        ST_PREFETCH_A,
        ST_PREFETCH_B,
        ST_ACC_FENCE,
        ST_CMD_ACC_FENCE,
        ST_BUF_SWAP,
        ST_GEMM,
        ST_OUTPUT
    } state_t;

    function automatic tile_count_t ceil_tiles(input logic [DIM_WIDTH-1:0] dim);
        logic [TILE_COUNT_WIDTH:0] extended;
        logic [TILE_COUNT_WIDTH:0] divisor;
        begin
            extended = {{(TILE_COUNT_WIDTH + 1 - DIM_WIDTH){1'b0}}, dim} +
                       tile_count_t'(SA_WIDTH - 1);
            divisor = (TILE_COUNT_WIDTH + 1)'(SA_WIDTH);
            return tile_count_t'(extended / divisor);
        end
    endfunction

    function automatic tile_count_t min_int_tile(
        input tile_count_t value,
        input int          limit
    );
        begin
            if (value > tile_count_t'(limit)) begin
                return tile_count_t'(limit);
            end
            return value;
        end
    endfunction

    function automatic logic [ADDR_WIDTH-1:0] addr_add_tile(
        input logic [ADDR_WIDTH-1:0] base,
        input tile_count_t           offset
    );
        begin
            return base + ADDR_WIDTH'(offset);
        end
    endfunction

    function automatic logic [LOAD_ROWS_WIDTH-1:0] tile_valid_rows(
        input logic [DIM_WIDTH-1:0] dim,
        input tile_count_t          tile_idx
    );
        logic [TILE_COUNT_WIDTH:0] dim_ext;
        logic [TILE_COUNT_WIDTH:0] tile_start;
        logic [TILE_COUNT_WIDTH:0] rows_left;
        begin
            dim_ext = {{(TILE_COUNT_WIDTH + 1 - DIM_WIDTH){1'b0}}, dim};
            tile_start = (TILE_COUNT_WIDTH + 1)'(tile_idx) *
                         (TILE_COUNT_WIDTH + 1)'(SA_WIDTH);
            if (dim_ext <= tile_start) begin
                return '0;
            end
            rows_left = dim_ext - tile_start;
            if (rows_left >= (TILE_COUNT_WIDTH + 1)'(SA_WIDTH)) begin
                return LOAD_ROWS_WIDTH'(SA_WIDTH);
            end
            return LOAD_ROWS_WIDTH'(rows_left);
        end
    endfunction

    function automatic logic [PACC_IDX_WIDTH-1:0] pacc_of(
        input tile_count_t local_m,
        input tile_count_t local_n,
        input tile_count_t block_n
    );
        tile_count_t pacc_full;
        begin
            pacc_full = (local_m * block_n) + local_n;
            return pacc_full[PACC_IDX_WIDTH-1:0];
        end
    endfunction

    function automatic logic [ABUF_IDX_WIDTH-1:0] abuf_slot(
        input logic group,
        input tile_count_t local_m
    );
        tile_count_t full_idx;
        begin
            full_idx = tile_count_t'(group ? ABUF_GROUP_SIZE : 0) + local_m;
            return full_idx[ABUF_IDX_WIDTH-1:0];
        end
    endfunction

    function automatic logic [BBUF_IDX_WIDTH-1:0] bbuf_slot(
        input logic group,
        input tile_count_t local_n
    );
        tile_count_t full_idx;
        begin
            full_idx = tile_count_t'(group ? BBUF_GROUP_SIZE : 0) + local_n;
            return full_idx[BBUF_IDX_WIDTH-1:0];
        end
    endfunction

    state_t state_q;

    logic [ADDR_WIDTH-1:0] a_base_q;
    logic [ADDR_WIDTH-1:0] b_base_q;
    logic [ADDR_WIDTH-1:0] c_base_q;
    logic [DIM_WIDTH-1:0] m_dim_q;
    logic [DIM_WIDTH-1:0] n_dim_q;
    tile_count_t tm_q;
    tile_count_t tn_q;
    tile_count_t tk_q;
    tile_count_t block_m_base_q;
    tile_count_t block_n_base_q;
    tile_count_t block_m_q;
    tile_count_t block_n_q;
    tile_count_t k_tile_q;
    tile_count_t load_idx_q;
    tile_count_t gemm_m_idx_q;
    tile_count_t gemm_n_idx_q;
    tile_count_t out_m_idx_q;
    tile_count_t out_n_idx_q;
    logic read_group_q;
    logic load_group_q;
    logic next_command_load_group_q;
    logic command_fence_pending_q;
    logic fence_before_swap_q;

    tile_count_t cmd_tm_comb;
    tile_count_t cmd_tn_comb;
    tile_count_t cmd_tk_comb;
    tile_count_t next_block_m_base_comb;
    tile_count_t next_block_n_base_comb;
    tile_count_t next_block_m_comb;
    tile_count_t next_block_n_comb;
    logic command_has_tiles_comb;
    logic has_next_block_comb;

    always_comb begin
        cmd_tm_comb = ceil_tiles(cmd_m_i);
        cmd_tn_comb = ceil_tiles(cmd_n_i);
        cmd_tk_comb = ceil_tiles(cmd_k_i);
        command_has_tiles_comb =
            (cmd_tm_comb != '0) && (cmd_tn_comb != '0) && (cmd_tk_comb != '0);
    end

    always_comb begin
        if ((block_n_base_q + tile_count_t'(BLOCK_N)) < tn_q) begin
            next_block_m_base_comb = block_m_base_q;
            next_block_n_base_comb = block_n_base_q + tile_count_t'(BLOCK_N);
            has_next_block_comb = 1'b1;
        end else if ((block_m_base_q + tile_count_t'(BLOCK_M)) < tm_q) begin
            next_block_m_base_comb = block_m_base_q + tile_count_t'(BLOCK_M);
            next_block_n_base_comb = '0;
            has_next_block_comb = 1'b1;
        end else begin
            next_block_m_base_comb = '0;
            next_block_n_base_comb = '0;
            has_next_block_comb = 1'b0;
        end

        next_block_m_comb = min_int_tile(tm_q - next_block_m_base_comb, BLOCK_M);
        next_block_n_comb = min_int_tile(tn_q - next_block_n_base_comb, BLOCK_N);
    end

    assign cmd_ready_o = (state_q == ST_IDLE);
    assign uop_valid_o = (state_q != ST_IDLE);

    always_comb begin
        uop_type_o    = UOP_LOAD_A;
        uop_addr_o    = '0;
        uop_abufidx_o = '0;
        uop_bbufidx_o = '0;
        uop_paccidx_o = '0;
        uop_valid_rows_o = '0;
        uop_accum_o   = 1'b0;

        unique case (state_q)
            ST_LOAD_A, ST_PREFETCH_A: begin
                uop_type_o = UOP_LOAD_A;
                uop_addr_o = addr_add_tile(
                    a_base_q,
                    ((block_m_base_q + load_idx_q) * tk_q) +
                    (state_q == ST_PREFETCH_A ? (k_tile_q + 1'b1) : k_tile_q)
                );
                uop_abufidx_o = abuf_slot(load_group_q, load_idx_q);
                uop_valid_rows_o = tile_valid_rows(m_dim_q, block_m_base_q + load_idx_q);
            end

            ST_LOAD_B, ST_PREFETCH_B: begin
                uop_type_o = UOP_LOAD_B;
                uop_addr_o = addr_add_tile(
                    b_base_q,
                    ((state_q == ST_PREFETCH_B ? (k_tile_q + 1'b1) : k_tile_q) * tn_q) +
                    block_n_base_q + load_idx_q
                );
                uop_bbufidx_o = bbuf_slot(load_group_q, load_idx_q);
                uop_valid_rows_o = tile_valid_rows(n_dim_q, block_n_base_q + load_idx_q);
            end

            ST_ACC_FENCE, ST_CMD_ACC_FENCE: begin
                uop_type_o = UOP_ACC_FENCE;
            end

            ST_BUF_SWAP: begin
                uop_type_o = UOP_BUF_SWAP;
            end

            ST_GEMM: begin
                uop_type_o    = UOP_GEMM;
                uop_abufidx_o = abuf_slot(read_group_q, gemm_m_idx_q);
                uop_bbufidx_o = bbuf_slot(read_group_q, gemm_n_idx_q);
                uop_paccidx_o = pacc_of(gemm_m_idx_q, gemm_n_idx_q, block_n_q);
                uop_accum_o   = (k_tile_q != '0);
            end

            ST_OUTPUT: begin
                uop_type_o = UOP_OUTPUT;
                uop_addr_o = addr_add_tile(
                    c_base_q,
                    ((block_m_base_q + out_m_idx_q) * tn_q) +
                    block_n_base_q + out_n_idx_q
                );
                uop_paccidx_o = pacc_of(out_m_idx_q, out_n_idx_q, block_n_q);
            end

            default: begin
            end
        endcase
    end

    wire cmd_fire = cmd_valid_i && cmd_ready_o;
    wire uop_fire = uop_valid_o && uop_ready_i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= ST_IDLE;
            a_base_q <= '0;
            b_base_q <= '0;
            c_base_q <= '0;
            m_dim_q <= '0;
            n_dim_q <= '0;
            tm_q <= '0;
            tn_q <= '0;
            tk_q <= '0;
            block_m_base_q <= '0;
            block_n_base_q <= '0;
            block_m_q <= '0;
            block_n_q <= '0;
            k_tile_q <= '0;
            load_idx_q <= '0;
            gemm_m_idx_q <= '0;
            gemm_n_idx_q <= '0;
            out_m_idx_q <= '0;
            out_n_idx_q <= '0;
            read_group_q <= 1'b0;
            load_group_q <= 1'b0;
            next_command_load_group_q <= 1'b0;
            command_fence_pending_q <= 1'b0;
            fence_before_swap_q <= 1'b0;
        end else begin
            if (state_q == ST_IDLE) begin
                if (cmd_fire && command_has_tiles_comb) begin
                    state_q <= ST_LOAD_A;
                    a_base_q <= cmd_a_base_i;
                    b_base_q <= cmd_b_base_i;
                    c_base_q <= cmd_c_base_i;
                    m_dim_q <= cmd_m_i;
                    n_dim_q <= cmd_n_i;
                    tm_q <= cmd_tm_comb;
                    tn_q <= cmd_tn_comb;
                    tk_q <= cmd_tk_comb;
                    block_m_base_q <= '0;
                    block_n_base_q <= '0;
                    block_m_q <= min_int_tile(cmd_tm_comb, BLOCK_M);
                    block_n_q <= min_int_tile(cmd_tn_comb, BLOCK_N);
                    k_tile_q <= '0;
                    load_idx_q <= '0;
                    gemm_m_idx_q <= '0;
                    gemm_n_idx_q <= '0;
                    out_m_idx_q <= '0;
                    out_n_idx_q <= '0;
                    read_group_q <= ~next_command_load_group_q;
                    load_group_q <= next_command_load_group_q;
                    command_fence_pending_q <= 1'b1;
                    fence_before_swap_q <= 1'b0;
                end
            end else if (uop_fire) begin
                unique case (state_q)
                    ST_LOAD_A, ST_PREFETCH_A: begin
                        if ((load_idx_q + 1'b1) < block_m_q) begin
                            load_idx_q <= load_idx_q + 1'b1;
                        end else begin
                            state_q <= (state_q == ST_LOAD_A) ? ST_LOAD_B : ST_PREFETCH_B;
                            load_idx_q <= '0;
                        end
                    end

                    ST_LOAD_B: begin
                        if ((load_idx_q + 1'b1) < block_n_q) begin
                            load_idx_q <= load_idx_q + 1'b1;
                        end else begin
                            state_q <= fence_before_swap_q ? ST_ACC_FENCE : ST_BUF_SWAP;
                            load_idx_q <= '0;
                        end
                    end

                    ST_PREFETCH_B: begin
                        if ((load_idx_q + 1'b1) < block_n_q) begin
                            load_idx_q <= load_idx_q + 1'b1;
                        end else begin
                            state_q <= command_fence_pending_q ? ST_CMD_ACC_FENCE : ST_GEMM;
                            load_idx_q <= '0;
                            gemm_m_idx_q <= '0;
                            gemm_n_idx_q <= '0;
                        end
                    end

                    ST_ACC_FENCE: begin
                        state_q <= ST_BUF_SWAP;
                        fence_before_swap_q <= 1'b0;
                    end

                    ST_CMD_ACC_FENCE: begin
                        state_q <= ST_GEMM;
                        command_fence_pending_q <= 1'b0;
                    end

                    ST_BUF_SWAP: begin
                        if ((k_tile_q + 1'b1) < tk_q) begin
                            state_q <= ST_PREFETCH_A;
                        end else begin
                            state_q <= command_fence_pending_q ? ST_CMD_ACC_FENCE : ST_GEMM;
                        end
                        read_group_q <= load_group_q;
                        load_group_q <= ~load_group_q;
                        load_idx_q <= '0;
                        gemm_m_idx_q <= '0;
                        gemm_n_idx_q <= '0;
                    end

                    ST_GEMM: begin
                        if ((gemm_n_idx_q + 1'b1) < block_n_q) begin
                            gemm_n_idx_q <= gemm_n_idx_q + 1'b1;
                        end else if ((gemm_m_idx_q + 1'b1) < block_m_q) begin
                            gemm_n_idx_q <= '0;
                            gemm_m_idx_q <= gemm_m_idx_q + 1'b1;
                        end else if ((k_tile_q + 1'b1) < tk_q) begin
                            state_q <= ST_BUF_SWAP;
                            k_tile_q <= k_tile_q + 1'b1;
                            gemm_m_idx_q <= '0;
                            gemm_n_idx_q <= '0;
                        end else begin
                            state_q <= ST_OUTPUT;
                            out_m_idx_q <= '0;
                            out_n_idx_q <= '0;
                        end
                    end

                    ST_OUTPUT: begin
                        if ((out_n_idx_q + 1'b1) < block_n_q) begin
                            out_n_idx_q <= out_n_idx_q + 1'b1;
                        end else if ((out_m_idx_q + 1'b1) < block_m_q) begin
                            out_n_idx_q <= '0;
                            out_m_idx_q <= out_m_idx_q + 1'b1;
                        end else if (has_next_block_comb) begin
                            state_q <= ST_LOAD_A;
                            block_m_base_q <= next_block_m_base_comb;
                            block_n_base_q <= next_block_n_base_comb;
                            block_m_q <= next_block_m_comb;
                            block_n_q <= next_block_n_comb;
                            k_tile_q <= '0;
                            load_idx_q <= '0;
                            gemm_m_idx_q <= '0;
                            gemm_n_idx_q <= '0;
                            out_m_idx_q <= '0;
                            out_n_idx_q <= '0;
                            read_group_q <= 1'b0;
                            load_group_q <= 1'b0;
                            command_fence_pending_q <= 1'b0;
                            fence_before_swap_q <= 1'b1;
                        end else begin
                            state_q <= ST_IDLE;
                            k_tile_q <= '0;
                            load_idx_q <= '0;
                            gemm_m_idx_q <= '0;
                            gemm_n_idx_q <= '0;
                            out_m_idx_q <= '0;
                            out_n_idx_q <= '0;
                            read_group_q <= 1'b0;
                            load_group_q <= 1'b0;
                            next_command_load_group_q <= ~read_group_q;
                            command_fence_pending_q <= 1'b0;
                            fence_before_swap_q <= 1'b0;
                        end
                    end

                    default: begin
                        state_q <= ST_IDLE;
                    end
                endcase
            end
        end
    end

endmodule

`default_nettype wire
