// Dynamic GEMM uop parser implementation.
//
// A command describes one complete BxMxNxK batched GEMM.  This dynamic parser
// treats the batch dimension as B independent MxNxK GEMMs in batch order; it
// does not merge tiles from different batches into one output block.  The
// parser splits each batch instance into
// tile-level uops for an SUBTILE_M x SUBTILE_N systolic array with a fixed
// SUBTILE_K reduction depth per GEMM uop.  Matrix layout and
// padding are assumed to be handled by software; addresses are tile-linear:
//   A tile(batch, m, k) address = a_base + batch * T_M * T_K + m * T_K + k
//   B tile(batch, k, n) address = b_base + batch * T_K * T_N + k * T_N + n
//   C tile(batch, m, n) address = c_base + batch * T_M * T_N + m * T_N + n
// where T_M/T_N use ceil(M / SUBTILE_M) and ceil(N / SUBTILE_N), while T_K
// uses ceil(K / SUBTILE_K).
//
// For each output block, the parser reserves a compact PACC rectangle:
//   paccidx = local_m * block_n + local_n
// Then for every K wave it emits all LOAD_A uops, all LOAD_B uops, and the
// Cartesian product GEMM uops.  After all K waves complete, it emits OUTPUT
// uops for the block and advances to the next output block.
//
// BlockM/BlockN are selected by blocksel upstream.  This module only expands
// the supplied block into LOAD/GEMM/OUTPUT uops.

`default_nettype none

module dynamic_uopparse_core #(
    parameter int SA_WIDTH       = 4,
    parameter int SUBTILE_M     = SA_WIDTH,
    parameter int SUBTILE_N     = SA_WIDTH,
    parameter int SUBTILE_K      = 32,
    parameter int ABUF_SIZE      = 4,
    parameter int BBUF_SIZE      = 4,
    parameter int PACC_NUM       = 16,
    parameter int ADDR_WIDTH     = 32,
    parameter int DIM_WIDTH      = 16,
    parameter int ABUF_IDX_WIDTH = (ABUF_SIZE <= 1) ? 1 : $clog2(ABUF_SIZE),
    parameter int BBUF_IDX_WIDTH = (BBUF_SIZE <= 1) ? 1 : $clog2(BBUF_SIZE),
    parameter int PACC_IDX_WIDTH = (PACC_NUM <= 1) ? 1 : $clog2(PACC_NUM),
    parameter int LOAD_ROWS_WIDTH = (((SUBTILE_M > SUBTILE_N) ? SUBTILE_M : SUBTILE_N) <= 1) ? 1 :
        $clog2(((SUBTILE_M > SUBTILE_N) ? SUBTILE_M : SUBTILE_N) + 1),
    parameter int BLOCK_M_WIDTH = (ABUF_SIZE <= 1) ? 1 : $clog2(ABUF_SIZE + 1),
    parameter int BLOCK_N_WIDTH = (BBUF_SIZE <= 1) ? 1 : $clog2(BBUF_SIZE + 1),
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
    input  logic [DIM_WIDTH-1:0] cmd_batch_i,
    input  logic [BLOCK_M_WIDTH-1:0] block_m_i,
    input  logic [BLOCK_N_WIDTH-1:0] block_n_i,

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

    initial begin
        if (SUBTILE_M <= 0 || (SUBTILE_M & (SUBTILE_M - 1)) != 0) begin
            $error("SUBTILE_M must be a positive power of two");
        end
        if (SUBTILE_N <= 0 || (SUBTILE_N & (SUBTILE_N - 1)) != 0) begin
            $error("SUBTILE_N must be a positive power of two");
        end
        if (SUBTILE_K <= 0 || (SUBTILE_K & (SUBTILE_K - 1)) != 0) begin
            $error("SUBTILE_K must be a positive power of two");
        end
        if (ABUF_SIZE <= 0) begin
            $error("ABUF_SIZE must be positive");
        end
        if (BBUF_SIZE <= 0) begin
            $error("BBUF_SIZE must be positive");
        end
        if (PACC_NUM <= 0) begin
            $error("PACC_NUM must be positive");
        end
        if (ADDR_WIDTH <= 0) begin
            $error("ADDR_WIDTH must be positive");
        end
        if (DIM_WIDTH <= 0) begin
            $error("DIM_WIDTH must be positive");
        end
    end

    typedef logic [TILE_COUNT_WIDTH-1:0] tile_count_t;
    localparam int SUBTILE_M_SHIFT = $clog2(SUBTILE_M);
    localparam int SUBTILE_N_SHIFT = $clog2(SUBTILE_N);
    localparam int SUBTILE_K_SHIFT = $clog2(SUBTILE_K);
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_LOAD_A,
        ST_LOAD_B,
        ST_GEMM,
        ST_OUTPUT
    } state_t;

    function automatic tile_count_t ceil_tiles(input logic [DIM_WIDTH-1:0] dim);
        return (tile_count_t'(dim) >> SUBTILE_M_SHIFT) +
            tile_count_t'((dim & DIM_WIDTH'(SUBTILE_M - 1)) != '0);
    endfunction

    function automatic tile_count_t ceil_n_tiles(input logic [DIM_WIDTH-1:0] dim);
        return (tile_count_t'(dim) >> SUBTILE_N_SHIFT) +
            tile_count_t'((dim & DIM_WIDTH'(SUBTILE_N - 1)) != '0);
    endfunction

    function automatic tile_count_t ceil_k_tiles(input logic [DIM_WIDTH-1:0] dim);
        return (tile_count_t'(dim) >> SUBTILE_K_SHIFT) +
            tile_count_t'((dim & DIM_WIDTH'(SUBTILE_K - 1)) != '0);
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
        logic [ADDR_WIDTH-1:0] addr_offset;
        begin
            addr_offset = ADDR_WIDTH'(offset);
            return base + addr_offset;
        end
    endfunction

    function automatic logic [LOAD_ROWS_WIDTH-1:0] tile_valid_rows(
        input logic [DIM_WIDTH-1:0] dim,
        input tile_count_t          tile_idx,
        input int                   tile_size
    );
        logic [TILE_COUNT_WIDTH:0] dim_ext;
        logic [TILE_COUNT_WIDTH:0] tile_start;
        logic [TILE_COUNT_WIDTH:0] rows_left;
        begin
            dim_ext = {{(TILE_COUNT_WIDTH + 1 - DIM_WIDTH){1'b0}}, dim};
            tile_start = (TILE_COUNT_WIDTH + 1)'(tile_idx) *
                         (TILE_COUNT_WIDTH + 1)'(tile_size);
            if (dim_ext <= tile_start) begin
                return '0;
            end
            rows_left = dim_ext - tile_start;
            if (rows_left >= (TILE_COUNT_WIDTH + 1)'(tile_size)) begin
                return LOAD_ROWS_WIDTH'(tile_size);
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

    state_t state_q;

    logic [ADDR_WIDTH-1:0] a_base_q;
    logic [ADDR_WIDTH-1:0] b_base_q;
    logic [ADDR_WIDTH-1:0] c_base_q;
    logic [DIM_WIDTH-1:0] m_dim_q;
    logic [DIM_WIDTH-1:0] n_dim_q;

    tile_count_t tm_q;
    tile_count_t tn_q;
    tile_count_t tk_q;
    tile_count_t batch_count_q;
    tile_count_t batch_q;
    tile_count_t block_m_base_q;
    tile_count_t block_n_base_q;
    tile_count_t block_m_q;
    tile_count_t block_n_q;
    tile_count_t block_m_limit_q;
    tile_count_t block_n_limit_q;
    tile_count_t k_tile_q;
    tile_count_t load_idx_q;
    tile_count_t gemm_m_idx_q;
    tile_count_t gemm_n_idx_q;
    tile_count_t out_m_idx_q;
    tile_count_t out_n_idx_q;

    tile_count_t cmd_tm_comb;
    tile_count_t cmd_tn_comb;
    tile_count_t cmd_tk_comb;
    tile_count_t next_block_m_base_comb;
    tile_count_t next_block_n_base_comb;
    tile_count_t next_block_m_comb;
    tile_count_t next_block_n_comb;
    tile_count_t next_batch_comb;
    logic command_has_tiles_comb;
    logic has_next_block_comb;

    always_comb begin
        cmd_tm_comb = ceil_tiles(cmd_m_i);
        cmd_tn_comb = ceil_n_tiles(cmd_n_i);
        cmd_tk_comb = ceil_k_tiles(cmd_k_i);
        command_has_tiles_comb =
            (cmd_batch_i != '0) &&
            (cmd_tm_comb != '0) && (cmd_tn_comb != '0) && (cmd_tk_comb != '0);
    end

    always_comb begin
        next_batch_comb = batch_q;
        if ((block_n_base_q + block_n_q) < tn_q) begin
            next_block_m_base_comb = block_m_base_q;
            next_block_n_base_comb = block_n_base_q + block_n_q;
            has_next_block_comb = 1'b1;
        end else if ((block_m_base_q + block_m_q) < tm_q) begin
            next_block_m_base_comb = block_m_base_q + block_m_q;
            next_block_n_base_comb = '0;
            has_next_block_comb = 1'b1;
        end else if ((batch_q + 1'b1) < batch_count_q) begin
            next_batch_comb = batch_q + 1'b1;
            next_block_m_base_comb = '0;
            next_block_n_base_comb = '0;
            has_next_block_comb = 1'b1;
        end else begin
            next_block_m_base_comb = '0;
            next_block_n_base_comb = '0;
            has_next_block_comb = 1'b0;
        end

        next_block_m_comb = min_int_tile(tm_q - next_block_m_base_comb,
                                         int'(block_m_limit_q));
        next_block_n_comb = min_int_tile(tn_q - next_block_n_base_comb,
                                         int'(block_n_limit_q));
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
            ST_LOAD_A: begin
                uop_type_o    = UOP_LOAD_A;
                uop_addr_o    = addr_add_tile(
                    a_base_q,
                    (batch_q * tm_q * tk_q) +
                    ((block_m_base_q + load_idx_q) * tk_q) + k_tile_q
                );
                uop_abufidx_o = load_idx_q[ABUF_IDX_WIDTH-1:0];
                uop_valid_rows_o = tile_valid_rows(
                    m_dim_q, block_m_base_q + load_idx_q, SUBTILE_M);
            end

            ST_LOAD_B: begin
                uop_type_o    = UOP_LOAD_B;
                uop_addr_o    = addr_add_tile(
                    b_base_q,
                    (batch_q * tk_q * tn_q) +
                    (k_tile_q * tn_q) + block_n_base_q + load_idx_q
                );
                uop_bbufidx_o = load_idx_q[BBUF_IDX_WIDTH-1:0];
                uop_valid_rows_o = tile_valid_rows(
                    n_dim_q, block_n_base_q + load_idx_q, SUBTILE_N);
            end

            ST_GEMM: begin
                uop_type_o    = UOP_GEMM;
                uop_abufidx_o = gemm_m_idx_q[ABUF_IDX_WIDTH-1:0];
                uop_bbufidx_o = gemm_n_idx_q[BBUF_IDX_WIDTH-1:0];
                uop_paccidx_o = pacc_of(gemm_m_idx_q, gemm_n_idx_q, block_n_q);
                uop_accum_o   = (k_tile_q != '0);
            end

            ST_OUTPUT: begin
                uop_type_o    = UOP_OUTPUT;
                uop_addr_o    = addr_add_tile(
                    c_base_q,
                    (batch_q * tm_q * tn_q) +
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
            batch_count_q <= '0;
            batch_q <= '0;
            block_m_base_q <= '0;
            block_n_base_q <= '0;
            block_m_q <= '0;
            block_n_q <= '0;
            block_m_limit_q <= '0;
            block_n_limit_q <= '0;
            k_tile_q <= '0;
            load_idx_q <= '0;
            gemm_m_idx_q <= '0;
            gemm_n_idx_q <= '0;
            out_m_idx_q <= '0;
            out_n_idx_q <= '0;
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
                    batch_count_q <= tile_count_t'(cmd_batch_i);
                    batch_q <= '0;
                    block_m_base_q <= '0;
                    block_n_base_q <= '0;
                    block_m_limit_q <= min_int_tile(cmd_tm_comb, int'(block_m_i));
                    block_n_limit_q <= min_int_tile(cmd_tn_comb, int'(block_n_i));
                    block_m_q <= min_int_tile(cmd_tm_comb, int'(block_m_i));
                    block_n_q <= min_int_tile(cmd_tn_comb, int'(block_n_i));
                    k_tile_q <= '0;
                    load_idx_q <= '0;
                    gemm_m_idx_q <= '0;
                    gemm_n_idx_q <= '0;
                    out_m_idx_q <= '0;
                    out_n_idx_q <= '0;
                end
            end else if (uop_fire) begin
                unique case (state_q)
                    ST_LOAD_A: begin
                        if ((load_idx_q + 1'b1) < block_m_q) begin
                            load_idx_q <= load_idx_q + 1'b1;
                        end else begin
                            state_q <= ST_LOAD_B;
                            load_idx_q <= '0;
                        end
                    end

                    ST_LOAD_B: begin
                        if ((load_idx_q + 1'b1) < block_n_q) begin
                            load_idx_q <= load_idx_q + 1'b1;
                        end else begin
                            state_q <= ST_GEMM;
                            load_idx_q <= '0;
                            gemm_m_idx_q <= '0;
                            gemm_n_idx_q <= '0;
                        end
                    end

                    ST_GEMM: begin
                        if ((gemm_n_idx_q + 1'b1) < block_n_q) begin
                            gemm_n_idx_q <= gemm_n_idx_q + 1'b1;
                        end else if ((gemm_m_idx_q + 1'b1) < block_m_q) begin
                            gemm_n_idx_q <= '0;
                            gemm_m_idx_q <= gemm_m_idx_q + 1'b1;
                        end else if ((k_tile_q + 1'b1) < tk_q) begin
                            state_q <= ST_LOAD_A;
                            k_tile_q <= k_tile_q + 1'b1;
                            load_idx_q <= '0;
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
                            batch_q <= next_batch_comb;
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
                        end else begin
                            state_q <= ST_IDLE;
                            k_tile_q <= '0;
                            load_idx_q <= '0;
                            gemm_m_idx_q <= '0;
                            gemm_n_idx_q <= '0;
                            out_m_idx_q <= '0;
                            out_n_idx_q <= '0;
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

// Public dynamic parser interface.  Physical resource sizes are accepted for
// integration with the backend, while block construction and emitted tags use
// the independent logical namespaces consumed by dynamic_rename.
module dynamic_uopparse #(
    parameter int SA_WIDTH        = 4,
    parameter int SUBTILE_M      = SA_WIDTH,
    parameter int SUBTILE_N      = SA_WIDTH,
    parameter int SUBTILE_K       = 32,
    parameter int ABUF_SIZE       = 4,
    parameter int BBUF_SIZE       = 4,
    parameter int PACC_NUM        = 16,
    parameter int ABUF_LOGIC_SIZE = ABUF_SIZE,
    parameter int BBUF_LOGIC_SIZE = BBUF_SIZE,
    parameter int PACC_LOGIC_SIZE = PACC_NUM,
    parameter int ADDR_WIDTH      = 32,
    parameter int DIM_WIDTH       = 16,
    parameter int ABUF_IDX_WIDTH  = (ABUF_LOGIC_SIZE <= 1) ? 1 : $clog2(ABUF_LOGIC_SIZE),
    parameter int BBUF_IDX_WIDTH  = (BBUF_LOGIC_SIZE <= 1) ? 1 : $clog2(BBUF_LOGIC_SIZE),
    parameter int PACC_IDX_WIDTH  = (PACC_LOGIC_SIZE <= 1) ? 1 : $clog2(PACC_LOGIC_SIZE),
    parameter int LOAD_ROWS_WIDTH = (((SUBTILE_M > SUBTILE_N) ? SUBTILE_M : SUBTILE_N) <= 1) ? 1 :
        $clog2(((SUBTILE_M > SUBTILE_N) ? SUBTILE_M : SUBTILE_N) + 1),
    parameter int BLOCK_M_WIDTH   = (ABUF_LOGIC_SIZE <= 1) ? 1 : $clog2(ABUF_LOGIC_SIZE + 1),
    parameter int BLOCK_N_WIDTH   = (BBUF_LOGIC_SIZE <= 1) ? 1 : $clog2(BBUF_LOGIC_SIZE + 1),
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
    input  logic [DIM_WIDTH-1:0] cmd_batch_i,
    input  logic [BLOCK_M_WIDTH-1:0] block_m_i,
    input  logic [BLOCK_N_WIDTH-1:0] block_n_i,
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

    initial begin
        if (SUBTILE_M <= 0 || (SUBTILE_M & (SUBTILE_M - 1)) != 0 ||
            SUBTILE_N <= 0 || (SUBTILE_N & (SUBTILE_N - 1)) != 0) begin
            $error("SUBTILE_M and SUBTILE_N must be positive powers of two");
        end
        if ((ABUF_LOGIC_SIZE <= 0) || (BBUF_LOGIC_SIZE <= 0) ||
            (PACC_LOGIC_SIZE <= 0)) begin
            $error("dynamic logical resource sizes must be positive");
        end
    end

    dynamic_uopparse_core #(
        .SA_WIDTH(SA_WIDTH),
        .SUBTILE_M(SUBTILE_M),
        .SUBTILE_N(SUBTILE_N),
        .SUBTILE_K(SUBTILE_K),
        .ABUF_SIZE(ABUF_LOGIC_SIZE),
        .BBUF_SIZE(BBUF_LOGIC_SIZE),
        .PACC_NUM(PACC_LOGIC_SIZE),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DIM_WIDTH(DIM_WIDTH),
        .ABUF_IDX_WIDTH(ABUF_IDX_WIDTH),
        .BBUF_IDX_WIDTH(BBUF_IDX_WIDTH),
        .PACC_IDX_WIDTH(PACC_IDX_WIDTH),
        .LOAD_ROWS_WIDTH(LOAD_ROWS_WIDTH),
        .BLOCK_M_WIDTH(BLOCK_M_WIDTH),
        .BLOCK_N_WIDTH(BLOCK_N_WIDTH),
        .TILE_COUNT_WIDTH(TILE_COUNT_WIDTH)
    ) u_core (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid_i(cmd_valid_i), .cmd_ready_o(cmd_ready_o),
        .cmd_a_base_i(cmd_a_base_i), .cmd_b_base_i(cmd_b_base_i),
        .cmd_c_base_i(cmd_c_base_i),
        .cmd_m_i(cmd_m_i), .cmd_n_i(cmd_n_i), .cmd_k_i(cmd_k_i),
        .cmd_batch_i(cmd_batch_i),
        .block_m_i(block_m_i), .block_n_i(block_n_i),
        .uop_valid_o(uop_valid_o), .uop_ready_i(uop_ready_i),
        .uop_type_o(uop_type_o), .uop_addr_o(uop_addr_o),
        .uop_abufidx_o(uop_abufidx_o), .uop_bbufidx_o(uop_bbufidx_o),
        .uop_paccidx_o(uop_paccidx_o), .uop_valid_rows_o(uop_valid_rows_o),
        .uop_accum_o(uop_accum_o)
    );

endmodule

`default_nettype wire
