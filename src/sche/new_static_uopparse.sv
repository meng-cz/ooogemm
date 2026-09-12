// Static GEMM parser with independent LOAD, GEMM and OUTPUT streams.
//
// Pipeline semantics:
//   * The first group preloads K-wave 0, then starts GEMM wave 0.
//   * While GEMM wave k is being issued, LOAD issues wave k+1 into the other
//     operand-buffer half.  GEMM wave k+1 is held until that load completes.
//   * The final K-wave GEMM overlaps the next output block's wave-0 LOAD into
//     the opposite operand-buffer half.
//   * The following boundary group overlaps the old block's OUTPUT, the new
//     block's wave-0 GEMM and (when present) the new block's wave-1 LOAD.
//   * A/B group swaps wait only for all group GEMMs to be issued and all group
//     LOADs to complete; GEMM completion never blocks following LOAD/GEMM.
//   * At output-block/KWave advance, tail GEMM outstanding is promoted to the
//     head counter.  The old block's OUTPUT opens only after that head reaches
//     zero, while the new block continues issuing GEMMs into the tail counter.
//   * OUTPUT completion does not hold the following waves of the new block.
//     It is checked only before entering the block after that, when the PACC
//     half being output would be reused by another wave-0 GEMM.
//
// LOAD/GEMM group ownership is deliberately implicit: the buffer index and
// the wave/block parity already identify the physical ping-pong half.

`default_nettype none

module new_static_uopparse #(
    parameter int SA_WIDTH = 32,
    parameter int SUBTILE_M = SA_WIDTH,
    parameter int SUBTILE_N = SA_WIDTH,
    parameter int SUBTILE_K = 32,
    parameter int ABUF_SIZE = 16,
    parameter int BBUF_SIZE = 16,
    parameter int PACC_NUM = 16,
    parameter int ADDR_WIDTH = 32,
    parameter int DIM_WIDTH = 16,
    parameter int ABUF_IDX_WIDTH = (ABUF_SIZE <= 1) ? 1 : $clog2(ABUF_SIZE),
    parameter int BBUF_IDX_WIDTH = (BBUF_SIZE <= 1) ? 1 : $clog2(BBUF_SIZE),
    parameter int PACC_IDX_WIDTH = (PACC_NUM <= 1) ? 1 : $clog2(PACC_NUM),
    parameter int LOAD_ROWS_WIDTH = (((SUBTILE_M > SUBTILE_N) ? SUBTILE_M : SUBTILE_N) <= 1) ? 1 :
        $clog2(((SUBTILE_M > SUBTILE_N) ? SUBTILE_M : SUBTILE_N) + 1),
    parameter int BLOCK_M_WIDTH = ((ABUF_SIZE / 2) <= 1) ? 1 : $clog2((ABUF_SIZE / 2) + 1),
    parameter int BLOCK_N_WIDTH = ((BBUF_SIZE / 2) <= 1) ? 1 : $clog2((BBUF_SIZE / 2) + 1),
    parameter int COUNT_WIDTH = 16
) (
    input logic clk,
    input logic rst_n,
    input logic cmd_valid_i,
    output logic cmd_ready_o,
    input logic [ADDR_WIDTH-1:0] cmd_a_base_i,
    input logic [ADDR_WIDTH-1:0] cmd_b_base_i,
    input logic [ADDR_WIDTH-1:0] cmd_c_base_i,
    input logic [DIM_WIDTH-1:0] cmd_m_i,
    input logic [DIM_WIDTH-1:0] cmd_n_i,
    input logic [DIM_WIDTH-1:0] cmd_k_i,
    input logic [DIM_WIDTH-1:0] cmd_batch_i,
    input logic [BLOCK_M_WIDTH-1:0] block_m_i,
    input logic [BLOCK_N_WIDTH-1:0] block_n_i,

    output logic load_valid_o,
    input logic load_ready_i,
    output logic load_is_b_o,
    output logic load_group_o,
    output logic [ADDR_WIDTH-1:0] load_addr_o,
    output logic [ABUF_IDX_WIDTH-1:0] load_abufidx_o,
    output logic [BBUF_IDX_WIDTH-1:0] load_bbufidx_o,
    output logic [LOAD_ROWS_WIDTH-1:0] load_valid_rows_o,

    output logic gemm_valid_o,
    input logic gemm_ready_i,
    output logic gemm_group_o,
    output logic [ABUF_IDX_WIDTH-1:0] gemm_abufidx_o,
    output logic [BBUF_IDX_WIDTH-1:0] gemm_bbufidx_o,
    output logic [PACC_IDX_WIDTH-1:0] gemm_paccidx_o,
    output logic gemm_accum_o,

    output logic output_valid_o,
    input logic output_ready_i,
    output logic output_group_o,
    output logic [ADDR_WIDTH-1:0] output_addr_o,
    output logic [PACC_IDX_WIDTH-1:0] output_paccidx_o,

    input logic load_done_valid_i,
    input logic gemm_done_valid_i,
    input logic output_done_valid_i,
    output logic cmd_done_valid_o
);

    localparam int A_GROUP = ABUF_SIZE / 2;
    localparam int B_GROUP = BBUF_SIZE / 2;
    localparam int ACC_GROUP = PACC_NUM / 2;
    localparam int SUBTILE_M_SHIFT = $clog2(SUBTILE_M);
    localparam int SUBTILE_N_SHIFT = $clog2(SUBTILE_N);
    localparam int SUBTILE_K_SHIFT = $clog2(SUBTILE_K);
    // Batch merge is different from a rectangular block: every flattened
    // tile consumes one slot from all three resource groups.
    localparam int MERGE_CAP = (A_GROUP < B_GROUP) ?
        ((A_GROUP < ACC_GROUP) ? A_GROUP : ACC_GROUP) :
        ((B_GROUP < ACC_GROUP) ? B_GROUP : ACC_GROUP);

    // Merge decisions only ever need products in [0, MERGE_CAP], so the merge
    // arithmetic is done in these narrow fields instead of count_t.
    localparam int MERGE_FACTOR_WIDTH = $clog2(MERGE_CAP + 2);
    localparam int MERGE_COUNT_WIDTH = $clog2(MERGE_CAP + 1);
    typedef logic [MERGE_COUNT_WIDTH-1:0] merge_count_t;
    typedef logic [2*MERGE_FACTOR_WIDTH-1:0] merge_product_t;

    // Load-issue counters only ever reach the block width, so they are kept in
    // this narrow field and compared with a narrow comparator instead of the
    // full count width.
    localparam int LOAD_IDX_WIDTH =
        ((BLOCK_M_WIDTH > BLOCK_N_WIDTH) ? BLOCK_M_WIDTH : BLOCK_N_WIDTH) + 1;
    typedef logic [LOAD_IDX_WIDTH-1:0] load_idx_t;

    typedef logic [DIM_WIDTH:0] count_t;
    typedef logic [COUNT_WIDTH-1:0] outstanding_t;
    typedef enum logic [2:0] {IDLE, PRELOAD, WAVE, OUTPUT_PRELOAD, DONE} state_t;
    state_t state_q;

    logic [ADDR_WIDTH-1:0] a_base_q, b_base_q, c_base_q;
    logic [DIM_WIDTH-1:0] m_q, n_q, k_q, batch_q;
    count_t tm_q, tn_q, tk_q;

    count_t bm_q, bn_q, batch_idx_q;
    count_t bm_limit_q, bn_limit_q;
    count_t block_m_base_q, block_n_base_q;
    // Registered block end coordinates: block_*_base_q + bm/bn is needed by
    // the next-descriptor logic every cycle, so the add is done once when the
    // descriptor is loaded instead of standing on the load-enable path.
    count_t block_m_end_q, block_n_end_q;
    logic merge_mode_q;
    count_t merge_base_q, merge_count_q;
    count_t merge_batch_base_q;
    merge_count_t merge_batch_count_q;
    // Batches still available from the current merge chunk base.  Keeping it
    // registered removes a full width add from the per-cycle descriptor path.
    count_t merge_batch_rem_q;
    // First-chunk merge descriptor, evaluated in the PRELOAD cycle from the
    // already registered command values (tiles_per_batch and capacity).  This
    // keeps the multiply/LUT chain out of the command-accept cycle.
    merge_count_t merge_batch_count_pre_comb;
    count_t merge_count_pre_comb;
    logic [MERGE_FACTOR_WIDTH:0] merge_need_pre_comb;
    // capacity + chunk batch count, refreshed with the chunk count.
    logic [MERGE_FACTOR_WIDTH:0] merge_need_q;
    logic load_base_group_q, acc_group_q;

    count_t gemm_wave_q;
    count_t gemm_m_q, gemm_n_q;
    logic gemm_sent_q;
    // cnt[0] tracks the prior KWave whose result may be waiting for OUTPUT;
    // cnt[1] tracks GEMMs issued by the current KWave.
    outstanding_t gemm_count_q [2];

    count_t load_wave_q;
    load_idx_t load_a_q, load_b_q;
    logic load_active_q, load_issue_done_q, load_ready_q;
    outstanding_t load_count_q;

    count_t output_m_q, output_n_q;
    logic output_issue_done_q;
    outstanding_t output_count_q;
    count_t output_bm_q, output_bn_q, output_batch_idx_q;
    count_t output_block_m_base_q, output_block_n_base_q;
    count_t output_merge_base_q, output_merge_count_q;
    logic output_acc_group_q;

    // Descriptor for the block which is loaded while the current block is
    // being output.  It is committed only after the current output is safe.
    logic next_exists_q;
    count_t next_bm_q, next_bn_q, next_batch_idx_q;
    count_t next_block_m_base_q, next_block_n_base_q;
    count_t next_merge_base_q, next_merge_count_q;
    count_t next_merge_batch_base_q;
    merge_count_t next_merge_batch_count_q;
    logic next_load_base_group_q, next_acc_group_q;

    function automatic count_t ceil_m_tiles(input logic [DIM_WIDTH-1:0] v);
        return (count_t'(v) >> SUBTILE_M_SHIFT) +
            count_t'((v & DIM_WIDTH'(SUBTILE_M - 1)) != '0);
    endfunction

    function automatic count_t ceil_n_tiles(input logic [DIM_WIDTH-1:0] v);
        return (count_t'(v) >> SUBTILE_N_SHIFT) +
            count_t'((v & DIM_WIDTH'(SUBTILE_N - 1)) != '0);
    endfunction

    function automatic count_t ceil_k_tiles(input logic [DIM_WIDTH-1:0] v);
        return (count_t'(v) >> SUBTILE_K_SHIFT) +
            count_t'((v & DIM_WIDTH'(SUBTILE_K - 1)) != '0);
    endfunction

    function automatic count_t min_count(input count_t v, input count_t limit);
        if (v > limit) return limit;
        return v;
    endfunction

    function automatic logic load_less(input load_idx_t a, input load_idx_t b);
        return a < b;
    endfunction

    // GEMM/OUTPUT block-local indices are bounded by the block width too, so
    // the issue conditions use the same narrow compare instead of a full
    // count-width magnitude compare.
    function automatic logic idx_less(input count_t a, input count_t b);
        return load_idx_t'(a) < load_idx_t'(b);
    endfunction

    function automatic logic idx_at_least(input count_t a, input count_t b);
        return load_idx_t'(a) >= load_idx_t'(b);
    endfunction

    // Magnitude compare with the two halves evaluated in parallel: the ripple
    // only spans half the count width before the halves are combined.
    localparam int COUNT_HALF = (DIM_WIDTH + 1) / 2;

    function automatic logic count_less(input count_t a, input count_t b);
        logic hi_lt;
        logic hi_eq;
        logic lo_lt;
        begin
            hi_lt = a[DIM_WIDTH:COUNT_HALF] < b[DIM_WIDTH:COUNT_HALF];
            hi_eq = a[DIM_WIDTH:COUNT_HALF] == b[DIM_WIDTH:COUNT_HALF];
            lo_lt = a[COUNT_HALF-1:0] < b[COUNT_HALF-1:0];
            return hi_lt || (hi_eq && lo_lt);
        end
    endfunction

    // min(top - end_pos, limit) for a "tiles left in this row/column" count.
    // Both the subtrahend and the limit are bounded by the block width, so the
    // exact result only needs a high-bit equality check plus a narrow low-bit
    // subtract: a full-width subtract followed by a comparator is not needed.
    localparam int REMAIN_LOW =
        (BLOCK_M_WIDTH > BLOCK_N_WIDTH) ? BLOCK_M_WIDTH : BLOCK_N_WIDTH;

    function automatic count_t remain_min_limit(
        input count_t top,
        input count_t end_pos,
        input count_t limit
    );
        logic same_high;
        logic low_ge;
        logic [REMAIN_LOW-1:0] diff_low;
        begin
            same_high = (top[DIM_WIDTH:REMAIN_LOW] ==
                         end_pos[DIM_WIDTH:REMAIN_LOW]);
            low_ge = (top[REMAIN_LOW-1:0] >= end_pos[REMAIN_LOW-1:0]);
            diff_low = top[REMAIN_LOW-1:0] - end_pos[REMAIN_LOW-1:0];
            if (same_high && low_ge && (diff_low < limit[REMAIN_LOW-1:0])) begin
                return count_t'(diff_low);
            end
            return limit;
        end
    endfunction

    // Merge mode is reserved for combining at least two independent batch
    // instances.  A single batch with several output tiles must use the
    // ordinary BM x BN Cartesian block; treating those tiles as merge entries
    // would load the same A tile once per output tile.
    function automatic logic merge_enabled(
        input logic [DIM_WIDTH-1:0] batch_count,
        input merge_product_t       tiles_per_batch
    );
        begin
            return (batch_count > 1) && (tiles_per_batch != '0) &&
                (tiles_per_batch <= merge_product_t'(MERGE_CAP >> 1));
        end
    endfunction

    // Tile counts are 17 bit wide, but every merge decision only depends on
    // whether tiles_per_batch = tiles_m * tiles_n is inside [1, MERGE_CAP].
    // Clamping both factors to MERGE_CAP before the product therefore gives a
    // small multiplier whose result is exact whenever the true product is in
    // range, and is guaranteed to be above the cap otherwise.

    // Any set bit above the clamp field already means the value is over the
    // cap, so the compare only needs an OR reduction of the high bits plus a
    // narrow compare on the low field instead of a full width magnitude
    // compare against MERGE_CAP.
    function automatic logic [MERGE_FACTOR_WIDTH-1:0] merge_factor_clamp(
        input count_t value
    );
        begin
            if ((value[DIM_WIDTH:MERGE_FACTOR_WIDTH] != '0) ||
                (value[MERGE_FACTOR_WIDTH-1:0] >
                 MERGE_FACTOR_WIDTH'(MERGE_CAP))) begin
                return MERGE_FACTOR_WIDTH'(MERGE_CAP + 1);
            end
            return MERGE_FACTOR_WIDTH'(value);
        end
    endfunction

    function automatic merge_product_t merge_tiles_per_batch(
        input count_t tiles_m,
        input count_t tiles_n
    );
        begin
            return merge_factor_clamp(tiles_m) * merge_factor_clamp(tiles_n);
        end
    endfunction

    // tiles_per_batch is the clamped product, so it fits MERGE_FACTOR_WIDTH
    // bits.  The capacity is a pure function of that narrow value, so it is
    // built as a one-hot decode plus a masked OR instead of a compare network
    // followed by an adder tree.
    localparam int MERGE_LUT_SIZE = MERGE_CAP + 2;

    function automatic merge_count_t merge_capacity_entry(input int idx);
        begin
            if ((idx >= 1) && (idx <= MERGE_CAP)) begin
                return merge_count_t'(MERGE_CAP / idx);
            end
            return merge_count_t'(0);
        end
    endfunction

    function automatic merge_count_t merge_batch_capacity(
        input merge_product_t tiles_per_batch
    );
        logic [MERGE_LUT_SIZE-1:0] hit;
        logic [MERGE_LUT_SIZE-1:0] terms;
        merge_count_t cap;
        begin
            for (int t = 0; t < MERGE_LUT_SIZE; t++) begin
                hit[t] = (tiles_per_batch == merge_product_t'(t));
            end
            for (int b = 0; b < MERGE_COUNT_WIDTH; b++) begin
                for (int t = 0; t < MERGE_LUT_SIZE; t++) begin
                    if (((merge_capacity_entry(t) >> b) & 1) != 0) begin
                        terms[t] = hit[t];
                    end else begin
                        terms[t] = 1'b0;
                    end
                end
                cap[b] = |terms;
            end
            return cap;
        end
    endfunction

    always_comb begin
        merge_batch_count_pre_comb =
            ((batch_q[DIM_WIDTH-1:MERGE_FACTOR_WIDTH] == 0) &&
             (batch_q[MERGE_FACTOR_WIDTH-1:0] <
              MERGE_FACTOR_WIDTH'(merge_capacity_q))) ?
            merge_count_t'(batch_q[MERGE_FACTOR_WIDTH-1:0]) :
            merge_capacity_q;
        merge_count_pre_comb = merge_tile_count(
            merge_batch_count_pre_comb, merge_tiles_per_batch_q);
        merge_need_pre_comb = (MERGE_FACTOR_WIDTH+1)'(merge_capacity_q) +
            (MERGE_FACTOR_WIDTH+1)'(merge_batch_count_pre_comb);
    end

    // More batches left after the current merge chunk?
    function automatic logic merge_chunk_has_more(
        input count_t remaining, input count_t chunk_count
    );
        begin
            return (remaining[DIM_WIDTH:MERGE_FACTOR_WIDTH] != '0) ||
                   (remaining[MERGE_FACTOR_WIDTH-1:0] >
                    chunk_count[MERGE_FACTOR_WIDTH-1:0]);
        end
    endfunction

    // Batch count of the next merge chunk, i.e. min(remaining - chunk_count,
    // capacity).  The result is at most MERGE_CAP, so a high-bit test plus a
    // narrow subtract replaces a full width subtract/min chain.  An
    // underflowing difference keeps the historical "clamped to capacity"
    // result.  "need" = chunk_count + capacity is kept in a register that is
    // refreshed whenever the chunk count changes, so the addition is not on
    // the per-cycle path.
    function automatic merge_count_t merge_next_chunk_batches(
        input count_t remaining,
        input count_t chunk_count,
        input merge_count_t capacity,
        input logic [MERGE_FACTOR_WIDTH:0] need
    );
        begin
            if ((remaining[DIM_WIDTH:MERGE_FACTOR_WIDTH] == '0) &&
                ((MERGE_FACTOR_WIDTH+1)'(remaining[MERGE_FACTOR_WIDTH-1:0]) >=
                 (MERGE_FACTOR_WIDTH+1)'(chunk_count[MERGE_FACTOR_WIDTH-1:0])) &&
                ((MERGE_FACTOR_WIDTH+1)'(remaining[MERGE_FACTOR_WIDTH-1:0]) <
                 need)) begin
                return merge_count_t'(
                    remaining[MERGE_FACTOR_WIDTH-1:0] -
                    chunk_count[MERGE_FACTOR_WIDTH-1:0]);
            end
            return capacity;
        end
    endfunction

    // Same clamp, but applied directly to a raw command dimension: the tile
    // count exceeds the cap exactly when the dimension exceeds cap << shift, so
    // the test only needs a high-bit OR plus a narrow compare, and the low tile
    // count is a narrow add plus a low-bit reduction.
    function automatic logic [MERGE_FACTOR_WIDTH-1:0] merge_factor_clamp_m(
        input logic [DIM_WIDTH-1:0] value
    );
        localparam int SHIFT = SUBTILE_M_SHIFT;
        logic [MERGE_COUNT_WIDTH-1:0] tiles;
        begin
            if ((value[DIM_WIDTH-1:MERGE_COUNT_WIDTH+SHIFT] != '0) ||
                (value[MERGE_COUNT_WIDTH+SHIFT-1:0] >
                 (MERGE_COUNT_WIDTH+SHIFT)'(MERGE_CAP << SHIFT))) begin
                return MERGE_FACTOR_WIDTH'(MERGE_CAP + 1);
            end
            tiles = MERGE_COUNT_WIDTH'(value[MERGE_COUNT_WIDTH+SHIFT-1:SHIFT]) +
                    MERGE_COUNT_WIDTH'(
                        |(value & DIM_WIDTH'((1 << SHIFT) - 1)));
            return MERGE_FACTOR_WIDTH'(tiles);
        end
    endfunction

    function automatic logic [MERGE_FACTOR_WIDTH-1:0] merge_factor_clamp_n(
        input logic [DIM_WIDTH-1:0] value
    );
        localparam int SHIFT = SUBTILE_N_SHIFT;
        logic [MERGE_COUNT_WIDTH-1:0] tiles;
        begin
            if ((value[DIM_WIDTH-1:MERGE_COUNT_WIDTH+SHIFT] != '0) ||
                (value[MERGE_COUNT_WIDTH+SHIFT-1:0] >
                 (MERGE_COUNT_WIDTH+SHIFT)'(MERGE_CAP << SHIFT))) begin
                return MERGE_FACTOR_WIDTH'(MERGE_CAP + 1);
            end
            tiles = MERGE_COUNT_WIDTH'(value[MERGE_COUNT_WIDTH+SHIFT-1:SHIFT]) +
                    MERGE_COUNT_WIDTH'(
                        |(value & DIM_WIDTH'((1 << SHIFT) - 1)));
            return MERGE_FACTOR_WIDTH'(tiles);
        end
    endfunction

    function automatic merge_product_t merge_tiles_per_batch_dim(
        input logic [DIM_WIDTH-1:0] dim_m,
        input logic [DIM_WIDTH-1:0] dim_n
    );
        begin
            return merge_factor_clamp_m(dim_m) * merge_factor_clamp_n(dim_n);
        end
    endfunction

    // merge_count = batch_count * tiles_per_batch is bounded by MERGE_CAP, so
    // both factors fit in the clamp field and the product stays small.
    // The batch count of a chunk is already clamped to MERGE_CAP by
    // merge_next_chunk_batches / the command path, so this only has to clamp
    // the (narrow) tiles_per_batch factor.
    function automatic count_t merge_tile_count(
        input merge_count_t batch_count,
        input merge_product_t tiles_per_batch
    );
        logic [MERGE_FACTOR_WIDTH-1:0] factor_b;
        logic [MERGE_FACTOR_WIDTH-1:0] factor_t;
        begin
            // No clamp needed on either factor: batch_count is already capped
            // at capacity, and when tiles_per_batch is out of range the
            // capacity (hence the batch count) is zero.
            factor_b = MERGE_FACTOR_WIDTH'(batch_count);
            factor_t = MERGE_FACTOR_WIDTH'(tiles_per_batch);
            return count_t'(factor_b * factor_t);
        end
    endfunction

    // Address offsets are expressed in tiles.  Widen each count before any
    // arithmetic so products cannot overflow count_t before reaching the
    // ADDR_WIDTH-wide memory address.
    function automatic logic [ADDR_WIDTH-1:0] addr_count(input count_t v);
        return ADDR_WIDTH'(v);
    endfunction

    function automatic logic [ABUF_IDX_WIDTH-1:0] abuf_slot(
        input logic group, input count_t idx);
        if (group) return ABUF_IDX_WIDTH'(A_GROUP) + ABUF_IDX_WIDTH'(idx);
        return ABUF_IDX_WIDTH'(idx);
    endfunction

    function automatic logic [BBUF_IDX_WIDTH-1:0] bbuf_slot(
        input logic group, input count_t idx);
        if (group) return BBUF_IDX_WIDTH'(B_GROUP) + BBUF_IDX_WIDTH'(idx);
        return BBUF_IDX_WIDTH'(idx);
    endfunction

    function automatic logic [PACC_IDX_WIDTH-1:0] pacc_slot(
        input logic group, input count_t idx);
        if (group) return PACC_IDX_WIDTH'(ACC_GROUP) + PACC_IDX_WIDTH'(idx);
        return PACC_IDX_WIDTH'(idx);
    endfunction

    function automatic logic [LOAD_ROWS_WIDTH-1:0] valid_rows(
        input count_t tile, input logic [DIM_WIDTH-1:0] dim, input int tile_size);
        count_t left;
        begin
            if (count_t'(dim) <= tile * count_t'(tile_size)) return '0;
            left = count_t'(dim) - tile * count_t'(tile_size);
            if (left > count_t'(tile_size)) return LOAD_ROWS_WIDTH'(tile_size);
            return LOAD_ROWS_WIDTH'(left);
        end
    endfunction

    count_t cmd_tm_comb, cmd_tn_comb, cmd_tk_comb;
    merge_product_t cmd_tiles_per_batch_comb;
    merge_count_t cmd_merge_capacity_comb;
    merge_count_t cmd_merge_batch_count_comb;
    logic cmd_merge_enabled_comb;

    always_comb begin
        cmd_tm_comb = ceil_m_tiles(cmd_m_i);
        cmd_tn_comb = ceil_n_tiles(cmd_n_i);
        cmd_tk_comb = ceil_k_tiles(cmd_k_i);
        cmd_tiles_per_batch_comb =
            merge_tiles_per_batch_dim(cmd_m_i, cmd_n_i);
        cmd_merge_capacity_comb =
            merge_batch_capacity(cmd_tiles_per_batch_comb);
        cmd_merge_enabled_comb =
            merge_enabled(cmd_batch_i, cmd_tiles_per_batch_comb);
        // min(batch_count, capacity) with capacity <= MERGE_CAP: any high bit
        // in the batch count already wins, so only the low field needs the
        // compare.
        cmd_merge_batch_count_comb =
            ((cmd_batch_i[DIM_WIDTH-1:MERGE_FACTOR_WIDTH] == '0) &&
             (cmd_batch_i[MERGE_FACTOR_WIDTH-1:0] <
              MERGE_FACTOR_WIDTH'(cmd_merge_capacity_comb))) ?
            merge_count_t'(cmd_batch_i[MERGE_FACTOR_WIDTH-1:0]) :
            cmd_merge_capacity_comb;
    end

    wire load_fire = load_valid_o && load_ready_i;
    wire gemm_fire = gemm_valid_o && gemm_ready_i;
    wire output_fire = output_valid_o && output_ready_i;
    wire load_done_event = load_done_valid_i && (load_count_q != 0);
    wire gemm_done_head_event = gemm_done_valid_i && (gemm_count_q[0] != 0);
    wire gemm_done_tail_event = gemm_done_valid_i &&
        (gemm_count_q[0] == 0) && (gemm_count_q[1] != 0);
    wire output_done_event = output_done_valid_i && (output_count_q != 0);
    wire wave_is_final = gemm_wave_q + 1 >= tk_q;
    wire wave_group_swap_ready = (state_q == WAVE) && gemm_sent_q &&
        (wave_is_final ? (!next_exists_comb || load_ready_q) : load_ready_q);
    wire kwave_advance = wave_group_swap_ready && wave_is_final &&
        output_issue_done_q && (output_count_q == 0);
    wire boundary_group_swap_ready = (state_q == OUTPUT_PRELOAD) &&
        next_exists_q && gemm_sent_q && ((tk_q <= 1) || load_ready_q) &&
        output_issue_done_q && (output_count_q == 0);

    // Next-block descriptor calculation.  The parser walks N blocks first,
    // then M blocks, then batches; merge mode walks a flat batch-tile list.
    count_t merge_chunk_count_comb;
    logic [MERGE_FACTOR_WIDTH:0] merge_chunk_need_comb;
    logic next_exists_comb;
    logic following_exists_comb;
    count_t next_bm_comb, next_bn_comb, next_batch_idx_comb;
    count_t next_mbase_comb, next_nbase_comb;
    count_t next_merge_base_comb, next_merge_count_comb;
    count_t next_merge_batch_base_comb;
    merge_count_t next_merge_batch_count_comb;
    // tiles_per_batch and the merge capacity depend only on the accepted
    // command (they are functions of tm_q/tn_q), so they are captured once in
    // the command cycle.  Keeping them out of the runtime descriptor cone
    // removes a clamp, a multiply and the capacity decode from the
    // load-bound path.
    merge_product_t merge_tiles_per_batch_q;
    merge_count_t merge_capacity_q;
    // Tile count of the block that the final K-wave preloads.  It is captured
    // when the current block starts, so the preload bound no longer has to be
    // recomputed inside the load-issue cone.
    merge_count_t fwd_merge_count_q;
    logic fwd_exists_q;
    count_t fwd_bm_q, fwd_bn_q;
    count_t block_m_end_comb, block_n_end_comb;
    always_comb begin
        // During PRELOAD the chunk descriptor has not been captured yet, so
        // read the PRELOAD-time value there.
        merge_chunk_count_comb = count_t'(merge_batch_count_q);
        merge_chunk_need_comb = merge_need_q;
        next_exists_comb = 1'b0;
        next_bm_comb = bm_q; next_bn_comb = bn_q;
        next_batch_idx_comb = batch_idx_q;
        next_mbase_comb = block_m_base_q; next_nbase_comb = block_n_base_q;
        next_merge_base_comb = merge_base_q;
        next_merge_count_comb = merge_count_q;
        next_merge_batch_base_comb = merge_batch_base_q;
        next_merge_batch_count_comb = merge_batch_count_q;
        block_m_end_comb = block_m_end_q;
        block_n_end_comb = block_n_end_q;

        if (merge_mode_q) begin
            if (merge_chunk_has_more(merge_batch_rem_q,
                                     merge_chunk_count_comb)) begin
                next_exists_comb = 1'b1;
                next_merge_base_comb = merge_base_q + merge_count_q;
                next_merge_batch_base_comb =
                    merge_batch_base_q + merge_chunk_count_comb;
                next_merge_batch_count_comb = merge_next_chunk_batches(
                    merge_batch_rem_q, merge_chunk_count_comb,
                    merge_capacity_q, merge_chunk_need_comb);
                next_merge_count_comb =
                    merge_tile_count(next_merge_batch_count_comb,
                                     merge_tiles_per_batch_q);
            end
        end else if (count_less(block_n_end_comb, tn_q)) begin
            next_exists_comb = 1'b1;
            next_nbase_comb = block_n_end_comb;
            next_bm_comb = bm_q;
            next_bn_comb = remain_min_limit(tn_q, block_n_end_comb,
                                            bn_limit_q);
        end else if (count_less(block_m_end_comb, tm_q)) begin
            next_exists_comb = 1'b1;
            next_mbase_comb = block_m_end_comb;
            next_nbase_comb = 0;
            next_bm_comb = remain_min_limit(tm_q, block_m_end_comb,
                                            bm_limit_q);
            next_bn_comb = bn_limit_q;
        end else if (batch_idx_q + 1 < batch_q) begin
            next_exists_comb = 1'b1;
            next_batch_idx_comb = batch_idx_q + 1'b1;
            next_mbase_comb = 0;
            next_nbase_comb = 0;
            next_bm_comb = bm_limit_q;
            next_bn_comb = bn_limit_q;
        end
    end

    // At a TK=1 boundary the descriptor in next_*_q becomes current at the
    // edge, while LOAD immediately starts looking one block farther ahead.
    // Register just the existence decision at that edge so load_valid_o does
    // not depend combinationally on the following descriptor calculation.
    always_comb begin
        if (merge_mode_q) begin
            following_exists_comb = merge_chunk_has_more(
                merge_batch_rem_q - count_t'(next_merge_batch_count_q),
                count_t'(next_merge_batch_count_q));
        end else begin
            following_exists_comb =
                count_less(next_block_n_base_q + next_bn_q, tn_q) ||
                count_less(next_block_m_base_q + next_bm_q, tm_q) ||
                ((next_batch_idx_q + 1'b1) < count_t'(batch_q));
        end
    end

    logic load_from_next_comb, load_next_exists_comb;
    // Load-issue bounds are selected once and then compared with the split
    // comparator, so the bound mux does not sit in front of a full-width
    // ripple compare.
    load_idx_t load_a_bound, load_b_bound;
    logic load_next_block_wave0_comb;
    count_t load_bm_comb, load_bn_comb, load_batch_comb;
    count_t load_mbase_comb, load_nbase_comb, load_merge_count_comb;
    count_t load_merge_batch_base_comb;
    logic load_group_comb;
    always_comb begin
        load_from_next_comb = (state_q == OUTPUT_PRELOAD) ||
            ((state_q == WAVE) && (gemm_wave_q + 1 >= tk_q));
        load_next_block_wave0_comb = (state_q == WAVE) &&
            (gemm_wave_q + 1 >= tk_q);
        load_next_exists_comb = (state_q == OUTPUT_PRELOAD) ?
            next_exists_q : fwd_exists_q;
        if (state_q == OUTPUT_PRELOAD) begin
            load_bm_comb = next_bm_q;
            load_bn_comb = next_bn_q;
            load_batch_comb = next_batch_idx_q;
            load_mbase_comb = next_block_m_base_q;
            load_nbase_comb = next_block_n_base_q;
            load_merge_count_comb = next_merge_count_q;
            load_merge_batch_base_comb = next_merge_batch_base_q;
            load_group_comb = next_load_base_group_q;
        end else if (load_from_next_comb) begin
            load_bm_comb = fwd_bm_q;
            load_bn_comb = fwd_bn_q;
            load_batch_comb = next_batch_idx_comb;
            load_mbase_comb = next_mbase_comb;
            load_nbase_comb = next_nbase_comb;
            load_merge_count_comb = fwd_merge_count_q;
            load_merge_batch_base_comb = next_merge_batch_base_comb;
            // wave 0 of the next block is written opposite the final GEMM's
            // operand half, independent of whether TK is odd or even.
            load_group_comb = ~(load_base_group_q ^ ~tk_q[0]);
        end else begin
            load_bm_comb = bm_q;
            load_bn_comb = bn_q;
            load_batch_comb = batch_idx_q;
            load_mbase_comb = block_m_base_q;
            load_nbase_comb = block_n_base_q;
            load_merge_count_comb = merge_count_q;
            load_merge_batch_base_comb = merge_batch_base_q;
            load_group_comb = load_base_group_q;
        end
    end

    // Decode only the offset inside a merge chunk.  It is bounded by
    // MERGE_CAP, unlike the old global flattened index, so a finite bank of
    // constant-coefficient comparisons is sufficient for batch/M/N recovery.
    //
    // floor(value / divisor) with a bounded quotient is expanded as the
    // population count of nested "value >= k * divisor" compares, which
    // replaces the former serial compare/subtract/mux chain with a parallel
    // compare/add network.
    // floor(value / divisor) for value <= MERGE_CAP.  The divisor is clamped
    // to the product field width first: any divisor above the cap makes every
    // "k * divisor <= value" test false, which is exactly the wanted result,
    // and it keeps the compare network in the narrow field.
    function automatic merge_count_t merge_bounded_quotient(
        input merge_product_t value,
        input count_t divisor
    );
        logic [MERGE_CAP-1:0] fits;
        merge_count_t part [MERGE_CAP];
        merge_product_t divisor_clamped;
        begin
            divisor_clamped =
                ((divisor[DIM_WIDTH:MERGE_FACTOR_WIDTH] != '0) ||
                 (divisor[MERGE_FACTOR_WIDTH-1:0] >
                  MERGE_FACTOR_WIDTH'(MERGE_CAP))) ?
                merge_product_t'(MERGE_CAP + 1) : merge_product_t'(divisor);
            fits = '0;
            for (int i = 0; i < MERGE_CAP; i++) begin
                part[i] = '0;
            end
            for (int k = 1; k < MERGE_CAP; k++) begin
                // A zero divisor keeps the historical "all offsets fit"
                // result; merge mode never runs with an empty tile shape.
                fits[k-1] = (divisor == '0) ? 1'b1 :
                    (value >= merge_product_t'(k) * divisor_clamped);
            end
            for (int i = 0; i < MERGE_CAP - 1; i++) begin
                part[i] = merge_count_t'(fits[i]);
            end
            for (int step = 1; step < MERGE_CAP - 1; step <<= 1) begin
                for (int i = 0; i + step < MERGE_CAP - 1; i += 2 * step) begin
                    part[i] = part[i] + part[i + step];
                end
            end
            return part[0];
        end
    endfunction

    merge_product_t load_merge_local_idx_comb;
    merge_count_t load_merge_batch_offset_comb;
    merge_product_t load_merge_in_batch_comb;
    count_t load_merge_batch_comb;
    merge_count_t load_merge_m_comb, load_merge_n_comb;
    always_comb begin
        load_merge_local_idx_comb =
            ((load_a_q < load_idx_t'(load_merge_count_comb)) ?
             merge_product_t'(load_a_q) : merge_product_t'(load_b_q));
        load_merge_batch_offset_comb = merge_bounded_quotient(
            load_merge_local_idx_comb,
            count_t'(merge_tiles_per_batch_q));
        load_merge_in_batch_comb = merge_product_t'(
            load_merge_local_idx_comb -
            merge_product_t'(load_merge_batch_offset_comb *
                             merge_tiles_per_batch_q));

        load_merge_batch_comb =
            load_merge_batch_base_comb + count_t'(load_merge_batch_offset_comb);
        load_merge_m_comb =
            merge_bounded_quotient(load_merge_in_batch_comb, tn_q);
        load_merge_n_comb = merge_count_t'(
            load_merge_in_batch_comb -
            merge_product_t'(load_merge_m_comb * tn_q));
    end

    logic gemm_from_next_comb;
    count_t gemm_bm_comb, gemm_bn_comb, gemm_merge_count_comb;
    logic gemm_base_group_comb, gemm_acc_group_comb;
    always_comb begin
        gemm_from_next_comb = (state_q == OUTPUT_PRELOAD) && next_exists_q;
        gemm_bm_comb = gemm_from_next_comb ? next_bm_q : bm_q;
        gemm_bn_comb = gemm_from_next_comb ? next_bn_q : bn_q;
        gemm_merge_count_comb = gemm_from_next_comb ? next_merge_count_q : merge_count_q;
        gemm_base_group_comb = gemm_from_next_comb ? next_load_base_group_q :
                                                     load_base_group_q;
        // Any GEMM issued in OUTPUT_PRELOAD belongs to the next block and
        // must use the PACC half opposite the tile currently being output.
        gemm_acc_group_comb = (state_q == OUTPUT_PRELOAD) ?
            ~output_acc_group_q : acc_group_q;
    end

    always_comb begin
        // load_active_q and load_issue_done_q already describe whether the
        // current registered issue sequence has work remaining.  Keeping
        // valid on this local state prevents address/merge/next-block logic
        // from entering load_fire and the outstanding-count feedback path.
        load_a_bound = load_idx_t'(load_from_next_comb ?
            (merge_mode_q ? load_merge_count_comb : load_bm_comb) :
            (merge_mode_q ? merge_count_q : bm_q));
        load_b_bound = load_idx_t'(load_from_next_comb ?
            (merge_mode_q ? load_merge_count_comb : load_bn_comb) :
            (merge_mode_q ? merge_count_q : bn_q));
        load_valid_o = load_active_q &&
            !load_issue_done_q &&
            ((state_q == PRELOAD) || (state_q == WAVE) ||
             (state_q == OUTPUT_PRELOAD));
        load_is_b_o = 1'b0;
        // The final GEMM wave preloads the next block's wave 0.  In that
        // special case the address and parity must use wave zero explicitly;
        // OUTPUT_PRELOAD resumes the normal parity walk at wave one.
        load_group_o = load_next_block_wave0_comb ? load_group_comb :
            (load_group_comb ^ load_wave_q[0]);
        load_addr_o = '0;
        load_abufidx_o = '0;
        load_bbufidx_o = '0;
        load_valid_rows_o = '0;

        gemm_valid_o = 1'b0;
        gemm_group_o = gemm_base_group_comb ^ gemm_wave_q[0];
        gemm_abufidx_o = abuf_slot(gemm_group_o, gemm_m_q);
        gemm_bbufidx_o = bbuf_slot(gemm_group_o, gemm_n_q);
        gemm_paccidx_o = pacc_slot(gemm_acc_group_comb,
            gemm_m_q * gemm_bn_comb + gemm_n_q);
        gemm_accum_o = gemm_wave_q != 0;

        output_valid_o = 1'b0;
        output_group_o = output_acc_group_q;
        output_addr_o = '0;
        output_paccidx_o = pacc_slot(output_acc_group_q,
            output_m_q * output_bn_q + output_n_q);

        if (load_active_q && (!load_from_next_comb || load_next_exists_comb) &&
            ((state_q == PRELOAD) || (state_q == WAVE) ||
             (state_q == OUTPUT_PRELOAD)) && !load_issue_done_q) begin
            if (load_less(load_a_q, load_a_bound)) begin
                load_is_b_o = 1'b0;
                if (merge_mode_q) begin
                    load_addr_o = a_base_q +
                        addr_count(load_merge_batch_comb) *
                        addr_count(tm_q) * addr_count(tk_q) +
                        addr_count(count_t'(load_merge_m_comb)) *
                        addr_count(tk_q) +
                        addr_count(load_next_block_wave0_comb ? 0 : load_wave_q);
                    load_abufidx_o = abuf_slot(load_group_o, count_t'(load_a_q));
                    load_valid_rows_o = valid_rows(
                        count_t'(load_merge_m_comb), m_q, SUBTILE_M);
                end else begin
                    load_addr_o = a_base_q +
                        addr_count(load_batch_comb) * addr_count(tm_q) *
                        addr_count(tk_q) +
                        (addr_count(load_mbase_comb) + addr_count(count_t'(load_a_q))) *
                        addr_count(tk_q) + addr_count(load_wave_q);
                    load_abufidx_o = abuf_slot(load_group_o, count_t'(load_a_q));
                    load_valid_rows_o = valid_rows(
                        load_mbase_comb + count_t'(load_a_q), m_q,
                        SUBTILE_M);
                end
            end else if (load_less(load_b_q, load_b_bound)) begin
                load_is_b_o = 1'b1;
                if (merge_mode_q) begin
                    load_addr_o = b_base_q +
                        addr_count(load_merge_batch_comb) *
                        addr_count(tk_q) * addr_count(tn_q) +
                        addr_count(load_next_block_wave0_comb ? 0 : load_wave_q) *
                        addr_count(tn_q) +
                        addr_count(count_t'(load_merge_n_comb));
                    load_bbufidx_o = bbuf_slot(load_group_o, count_t'(load_b_q));
                    load_valid_rows_o = valid_rows(
                        count_t'(load_merge_n_comb), n_q, SUBTILE_N);
                end else begin
                    load_addr_o = b_base_q +
                        addr_count(load_batch_comb) * addr_count(tk_q) *
                        addr_count(tn_q) +
                        addr_count(load_next_block_wave0_comb ? 0 : load_wave_q) *
                        addr_count(tn_q) +
                        addr_count(load_nbase_comb) + addr_count(count_t'(load_b_q));
                    load_bbufidx_o = bbuf_slot(load_group_o, count_t'(load_b_q));
                    load_valid_rows_o = valid_rows(
                        load_nbase_comb + count_t'(load_b_q), n_q, SUBTILE_N);
                end
            end
        end

        if (((state_q == WAVE) || gemm_from_next_comb) && !gemm_sent_q &&
            (merge_mode_q ? idx_less(gemm_m_q, gemm_merge_count_comb) :
             (idx_less(gemm_m_q, gemm_bm_comb) &&
              idx_less(gemm_n_q, gemm_bn_comb)))) begin
            gemm_valid_o = 1'b1;
            gemm_abufidx_o = abuf_slot(gemm_group_o, gemm_m_q);
            gemm_bbufidx_o = bbuf_slot(gemm_group_o,
                merge_mode_q ? gemm_m_q : gemm_n_q);
            gemm_paccidx_o = pacc_slot(gemm_acc_group_comb,
                merge_mode_q ? gemm_m_q : gemm_m_q * gemm_bn_comb + gemm_n_q);
        end

        if ((state_q == OUTPUT_PRELOAD) && !output_issue_done_q &&
            (gemm_count_q[0] == 0) &&
            (merge_mode_q ? idx_less(output_m_q, output_merge_count_q) :
             (idx_less(output_m_q, output_bm_q) &&
              idx_less(output_n_q, output_bn_q)))) begin
            output_valid_o = 1'b1;
            output_addr_o = c_base_q +
                (merge_mode_q ?
                    (addr_count(output_merge_base_q) + addr_count(output_m_q)) :
                    (addr_count(output_batch_idx_q) * addr_count(tm_q) *
                     addr_count(tn_q) +
                     (addr_count(output_block_m_base_q) + addr_count(output_m_q)) *
                     addr_count(tn_q) + addr_count(output_block_n_base_q) +
                     addr_count(output_n_q)));
            output_paccidx_o = pacc_slot(output_acc_group_q,
                merge_mode_q ? output_m_q :
                output_m_q * output_bn_q + output_n_q);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= IDLE;
            load_count_q <= '0;
            gemm_count_q[0] <= '0;
            gemm_count_q[1] <= '0;
            output_count_q <= '0;
            load_active_q <= 1'b0;
            load_issue_done_q <= 1'b0;
            load_ready_q <= 1'b0;
            block_m_end_q <= '0;
            block_n_end_q <= '0;
            merge_tiles_per_batch_q <= '0;
            merge_capacity_q <= '0;
            fwd_merge_count_q <= '0;
            fwd_exists_q <= 1'b0;
            fwd_bm_q <= '0;
            fwd_bn_q <= '0;
            gemm_sent_q <= 1'b0;
            output_issue_done_q <= 1'b1;
            output_bm_q <= '0; output_bn_q <= '0;
            output_batch_idx_q <= '0;
            output_block_m_base_q <= '0; output_block_n_base_q <= '0;
            output_merge_base_q <= '0; output_merge_count_q <= '0;
            output_acc_group_q <= 1'b0;
            next_exists_q <= 1'b0;
            merge_batch_base_q <= '0;
            merge_batch_count_q <= '0;
            merge_batch_rem_q <= '0;
            merge_need_q <= '0;
            next_merge_batch_base_q <= '0;
            next_merge_batch_count_q <= '0;
            bm_limit_q <= '0;
            bn_limit_q <= '0;
            end else begin
                // All three counters use net updates, so a completion and a new
            // issue in one cycle do not overwrite one another.
            if (load_fire && !load_done_event)
                load_count_q <= load_count_q + 1'b1;
            else if (!load_fire && load_done_event)
                load_count_q <= load_count_q - 1'b1;
            if (kwave_advance) begin
                // Completion is ordered.  A same-cycle completion with an
                // empty head belongs to the tail being promoted.
                gemm_count_q[0] <= gemm_count_q[1] -
                    outstanding_t'(gemm_done_tail_event);
                gemm_count_q[1] <= '0;
            end else begin
                if (gemm_done_head_event)
                    gemm_count_q[0] <= gemm_count_q[0] - 1'b1;
                unique case ({gemm_fire, gemm_done_tail_event})
                    2'b10: gemm_count_q[1] <= gemm_count_q[1] + 1'b1;
                    2'b01: gemm_count_q[1] <= gemm_count_q[1] - 1'b1;
                    default: begin
                    end
                endcase
            end
            if (output_fire && !output_done_event)
                output_count_q <= output_count_q + 1'b1;
            else if (!output_fire && output_done_event)
                output_count_q <= output_count_q - 1'b1;

            if (load_done_event && load_issue_done_q && load_count_q == 1)
                load_ready_q <= 1'b1;

            if (state_q == IDLE && cmd_valid_i && cmd_ready_o) begin
                a_base_q <= cmd_a_base_i; b_base_q <= cmd_b_base_i; c_base_q <= cmd_c_base_i;
                m_q <= cmd_m_i; n_q <= cmd_n_i; k_q <= cmd_k_i; batch_q <= cmd_batch_i;
                tm_q <= cmd_tm_comb;
                tn_q <= cmd_tn_comb;
                tk_q <= cmd_tk_comb;
                // The selector's block is a resource upper bound; clip edge
                // blocks to the actual tile shape before emitting any uops.
                bm_q <= min_count(cmd_tm_comb, count_t'(block_m_i));
                bn_q <= min_count(cmd_tn_comb, count_t'(block_n_i));
                block_m_end_q <= min_count(cmd_tm_comb, count_t'(block_m_i));
                block_n_end_q <= min_count(cmd_tn_comb, count_t'(block_n_i));
                bm_limit_q <= min_count(cmd_tm_comb, count_t'(block_m_i));
                bn_limit_q <= min_count(cmd_tn_comb, count_t'(block_n_i));
                batch_idx_q <= 0; block_m_base_q <= 0; block_n_base_q <= 0;
                merge_mode_q <= cmd_merge_enabled_comb;
                merge_base_q <= 0;
                merge_count_q <= cmd_merge_enabled_comb ?
                    merge_tile_count(cmd_merge_batch_count_comb,
                                     cmd_tiles_per_batch_comb) : '0;
                merge_batch_base_q <= '0;
                merge_batch_count_q <= cmd_merge_enabled_comb ?
                    cmd_merge_batch_count_comb : '0;
                merge_batch_rem_q <= count_t'(cmd_batch_i);
                merge_need_q <= (MERGE_FACTOR_WIDTH+1)'(cmd_merge_capacity_comb) +
                    (MERGE_FACTOR_WIDTH+1)'(cmd_merge_batch_count_comb);
                merge_tiles_per_batch_q <= cmd_tiles_per_batch_comb;
                merge_capacity_q <= cmd_merge_capacity_comb;
                load_base_group_q <= 1'b0; acc_group_q <= 1'b0;
                load_wave_q <= 0; load_a_q <= 0; load_b_q <= 0;
                load_active_q <= 1'b1; load_issue_done_q <= 1'b0; load_ready_q <= 1'b0;
                gemm_count_q[0] <= 0; gemm_count_q[1] <= 0;
                output_count_q <= 0;
                output_issue_done_q <= 1'b1;
                state_q <= PRELOAD;
            end else begin
                if (load_fire) begin
                    if (!load_is_b_o) load_a_q <= load_a_q + 1'b1;
                    else load_b_q <= load_b_q + 1'b1;
                    if ((!load_is_b_o &&
                         !load_less(load_a_q + LOAD_IDX_WIDTH'(1), load_a_bound) &&
                         !load_less(load_b_q, load_b_bound)) ||
                        (load_is_b_o &&
                         !load_less(load_b_q + LOAD_IDX_WIDTH'(1), load_b_bound) &&
                         !load_less(load_a_q, load_a_bound))) begin
                        load_issue_done_q <= 1'b1;
                    end
                end

                if (gemm_fire) begin
                    gemm_sent_q <= merge_mode_q ?
                        idx_at_least(gemm_m_q + 1'b1, gemm_merge_count_comb) :
                        (idx_at_least(gemm_m_q + 1'b1, gemm_bm_comb) &&
                         idx_at_least(gemm_n_q + 1'b1, gemm_bn_comb));
                    if (merge_mode_q || idx_at_least(gemm_n_q + 1'b1,
                                                     gemm_bn_comb)) begin
                        gemm_m_q <= gemm_m_q + 1'b1; gemm_n_q <= 0;
                    end else gemm_n_q <= gemm_n_q + 1'b1;
                end
                if (output_fire) begin
                    if (merge_mode_q || idx_at_least(output_n_q + 1'b1,
                                                     output_bn_q)) begin
                        output_m_q <= output_m_q + 1'b1; output_n_q <= 0;
                    end else output_n_q <= output_n_q + 1'b1;
                    if ((!merge_mode_q &&
                         idx_at_least(output_m_q + 1'b1, output_bm_q) &&
                         idx_at_least(output_n_q + 1'b1, output_bn_q)) ||
                        (merge_mode_q &&
                         idx_at_least(output_m_q + 1'b1,
                                      output_merge_count_q)))
                        output_issue_done_q <= 1'b1;
                end
                if ((state_q == PRELOAD) && load_issue_done_q && load_count_q == 0) begin
                    gemm_wave_q <= 0; gemm_m_q <= 0; gemm_n_q <= 0;
                    gemm_sent_q <= 1'b0;
                    load_ready_q <= 1'b0;
                    // Values the final wave will need are already known here.
                    fwd_merge_count_q <= next_merge_count_comb;
                    fwd_exists_q <= next_exists_comb;
                    // Descriptor one step past the block that just became
                    // current, evaluated on the committed values.
                    if (count_less(next_block_n_base_q + next_bn_q, tn_q)) begin
                        fwd_bn_q <= remain_min_limit(
                            tn_q, next_block_n_base_q + next_bn_q, bn_limit_q);
                        fwd_bm_q <= next_bm_q;
                    end else if (count_less(next_block_m_base_q + next_bm_q,
                                           tm_q)) begin
                        fwd_bn_q <= bn_limit_q;
                        fwd_bm_q <= remain_min_limit(
                            tm_q, next_block_m_base_q + next_bm_q, bm_limit_q);
                    end else begin
                        fwd_bn_q <= bn_limit_q;
                        fwd_bm_q <= bm_limit_q;
                    end
                    fwd_bm_q <= next_bm_comb;
                    fwd_bn_q <= next_bn_comb;

                    if (tk_q > 1) begin
                        load_wave_q <= 1; load_a_q <= 0; load_b_q <= 0;
                        load_active_q <= 1'b1; load_issue_done_q <= 1'b0;
                    end else begin
                        load_wave_q <= 0; load_a_q <= 0; load_b_q <= 0;
                        load_active_q <= next_exists_comb;
                        load_issue_done_q <= 1'b0;
                    end
                    state_q <= WAVE;
                end

                if ((!wave_is_final && wave_group_swap_ready) || kwave_advance) begin
                    if (gemm_wave_q + 1 < tk_q) begin
                        gemm_wave_q <= gemm_wave_q + 1'b1;
                        gemm_m_q <= 0; gemm_n_q <= 0; gemm_sent_q <= 1'b0;
                        load_ready_q <= 1'b0;
                        if (gemm_wave_q + 2 < tk_q) begin
                            load_wave_q <= gemm_wave_q + 2;
                            load_a_q <= 0; load_b_q <= 0;
                            load_active_q <= 1'b1; load_issue_done_q <= 1'b0;
                        end else begin
                            // The next GEMM is this block's final K-wave, so
                            // preload the following block's wave 0 alongside it.
                            load_wave_q <= 0;
                            load_a_q <= 0; load_b_q <= 0;
                            load_active_q <= next_exists_comb;
                            load_issue_done_q <= 1'b0;
                        end
                    end else begin
                        output_m_q <= 0; output_n_q <= 0;
                        output_issue_done_q <= 1'b0;
                        output_bm_q <= bm_q;
                        output_bn_q <= bn_q;
                        output_batch_idx_q <= batch_idx_q;
                        output_block_m_base_q <= block_m_base_q;
                        output_block_n_base_q <= block_n_base_q;
                        output_merge_base_q <= merge_base_q;
                        output_merge_count_q <= merge_count_q;
                        output_acc_group_q <= acc_group_q;
                        next_exists_q <= next_exists_comb;
                        next_bm_q <= next_bm_comb; next_bn_q <= next_bn_comb;
                        next_batch_idx_q <= next_batch_idx_comb;
                        next_block_m_base_q <= next_mbase_comb;
                        next_block_n_base_q <= next_nbase_comb;
                        next_merge_base_q <= next_merge_base_comb;
                        next_merge_count_q <= next_merge_count_comb;
                        next_merge_batch_base_q <= next_merge_batch_base_comb;
                        next_merge_batch_count_q <= next_merge_batch_count_comb;
                        next_load_base_group_q <= load_group_comb;
                        // Derive the next PACC half from the half being
                        // retired, rather than from a separately toggled
                        // state bit.  This keeps the ownership transition
                        // correct even when OUTPUT and the next block's
                        // wave-0 GEMM overlap in OUTPUT_PRELOAD.
                        next_acc_group_q <= ~acc_group_q;
                        // PACC ownership changes at KWave advance.  OUTPUT uses
                        // the separately captured old-half descriptor above.
                        acc_group_q <= ~output_acc_group_q;
                        gemm_wave_q <= 0;
                        gemm_m_q <= 0; gemm_n_q <= 0;
                        gemm_sent_q <= 1'b0;
                        load_ready_q <= 1'b0;
                        if (next_exists_comb && tk_q > 1) begin
                            load_wave_q <= 1; load_a_q <= 0; load_b_q <= 0;
                            load_active_q <= 1'b1; load_issue_done_q <= 1'b0;
                        end else load_active_q <= 1'b0;
                        state_q <= OUTPUT_PRELOAD;
                    end
                end

                if (boundary_group_swap_ready) begin
                    bm_q <= next_bm_q; bn_q <= next_bn_q;
                    batch_idx_q <= next_batch_idx_q;
                    block_m_base_q <= next_block_m_base_q;
                    block_n_base_q <= next_block_n_base_q;
                    block_m_end_q <= next_block_m_base_q + next_bm_q;
                    block_n_end_q <= next_block_n_base_q + next_bn_q;
                    merge_base_q <= next_merge_base_q;
                    merge_count_q <= next_merge_count_q;
                    merge_batch_base_q <= next_merge_batch_base_q;
                    merge_batch_count_q <= next_merge_batch_count_q;
                    // Consumption happens on the chunk that is being retired.
                    merge_batch_rem_q <= merge_batch_rem_q -
                        count_t'(merge_batch_count_q);
                    merge_need_q <= (MERGE_FACTOR_WIDTH+1)'(merge_capacity_q) +
                        (MERGE_FACTOR_WIDTH+1)'(next_merge_batch_count_q);
                    // Same quantities for the block that just became current.
                    fwd_merge_count_q <= merge_count_t'(merge_tile_count(
                        merge_next_chunk_batches(
                            merge_batch_rem_q -
                                count_t'(merge_batch_count_q),
                            count_t'(next_merge_batch_count_q),
                            merge_capacity_q,
                            (MERGE_FACTOR_WIDTH+1)'(merge_capacity_q) +
                                (MERGE_FACTOR_WIDTH+1)'(next_merge_batch_count_q)),
                        merge_tiles_per_batch_q));
                    fwd_exists_q <= next_exists_comb;
                    load_base_group_q <= next_load_base_group_q;
                    acc_group_q <= next_acc_group_q;
                    load_ready_q <= 1'b0;
                    load_a_q <= 0; load_b_q <= 0;
                    load_issue_done_q <= 1'b0;
                    if (tk_q > 1) begin
                        gemm_wave_q <= 1;
                        gemm_m_q <= 0; gemm_n_q <= 0;
                        gemm_sent_q <= 1'b0;
                        if (tk_q > 2) begin
                            load_wave_q <= 2;
                            load_active_q <= 1'b1;
                        end else begin
                            // For TK=2, waves 0 and 1 of the committed block
                            // are already resident.  Only preload again when a
                            // block exists after the one being committed.
                            load_wave_q <= 0;
                            load_active_q <= following_exists_comb;
                        end
                        load_issue_done_q <= 1'b0;
                    end else begin
                        // wave 0 was already executed in this boundary group;
                        // WAVE now represents its completed final K-wave while
                        // preloading the block after it, if one exists.
                        gemm_wave_q <= 0;
                        gemm_m_q <= 0; gemm_n_q <= 0;
                        gemm_sent_q <= 1'b1;
                        load_wave_q <= 0;
                        load_active_q <= following_exists_comb;
                    end
                    state_q <= WAVE;
                end else if ((state_q == OUTPUT_PRELOAD) && !next_exists_q &&
                             output_issue_done_q && output_count_q == 0) begin
                    state_q <= DONE;
                end

                if (state_q == DONE) state_q <= IDLE;
            end
        end
    end

    assign cmd_ready_o = state_q == IDLE;
    assign cmd_done_valid_o = state_q == DONE;

    initial begin
        if (SUBTILE_M <= 0 || (SUBTILE_M & (SUBTILE_M - 1)) != 0)
            $error("SUBTILE_M must be a positive power of two");
        if (SUBTILE_N <= 0 || (SUBTILE_N & (SUBTILE_N - 1)) != 0)
            $error("SUBTILE_N must be a positive power of two");
        if (SUBTILE_K <= 0 || (SUBTILE_K & (SUBTILE_K - 1)) != 0)
            $error("SUBTILE_K must be a positive power of two");
        if (ABUF_SIZE < 2 || BBUF_SIZE < 2 || PACC_NUM < 2 ||
            (ABUF_SIZE & 1) != 0 || (BBUF_SIZE & 1) != 0 || (PACC_NUM & 1) != 0)
            $error("buffers and PACC must have two even ping-pong halves");
    end
endmodule

`default_nettype wire
