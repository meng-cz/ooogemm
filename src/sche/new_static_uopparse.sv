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
    parameter int SUBTILE_K = 32,
    parameter int ABUF_SIZE = 16,
    parameter int BBUF_SIZE = 16,
    parameter int PACC_NUM = 16,
    parameter int ADDR_WIDTH = 32,
    parameter int DIM_WIDTH = 16,
    parameter int ABUF_IDX_WIDTH = (ABUF_SIZE <= 1) ? 1 : $clog2(ABUF_SIZE),
    parameter int BBUF_IDX_WIDTH = (BBUF_SIZE <= 1) ? 1 : $clog2(BBUF_SIZE),
    parameter int PACC_IDX_WIDTH = (PACC_NUM <= 1) ? 1 : $clog2(PACC_NUM),
    parameter int LOAD_ROWS_WIDTH = (SA_WIDTH <= 1) ? 1 : $clog2(SA_WIDTH + 1),
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
    // A normal rectangular block consumes BM A slots, BN B slots, and
    // BM*BN PACC slots.  Batch merge is different: every flattened tile
    // consumes one slot from all three resources.
    localparam int BLOCK_CAP = ACC_GROUP;
    localparam int MERGE_CAP = (A_GROUP < B_GROUP) ?
        ((A_GROUP < ACC_GROUP) ? A_GROUP : ACC_GROUP) :
        ((B_GROUP < ACC_GROUP) ? B_GROUP : ACC_GROUP);

    typedef logic [DIM_WIDTH:0] count_t;
    typedef logic [COUNT_WIDTH-1:0] outstanding_t;
    typedef enum logic [2:0] {IDLE, PRELOAD, WAVE, OUTPUT_PRELOAD, DONE} state_t;
    state_t state_q;

    logic [ADDR_WIDTH-1:0] a_base_q, b_base_q, c_base_q;
    logic [DIM_WIDTH-1:0] m_q, n_q, k_q, batch_q;
    count_t tm_q, tn_q, tk_q;

    count_t bm_q, bn_q, batch_idx_q;
    count_t block_m_base_q, block_n_base_q;
    logic merge_mode_q;
    count_t merge_base_q, merge_count_q;
    logic load_base_group_q, acc_group_q;

    count_t gemm_wave_q;
    count_t gemm_m_q, gemm_n_q;
    logic gemm_sent_q;
    // cnt[0] tracks the prior KWave whose result may be waiting for OUTPUT;
    // cnt[1] tracks GEMMs issued by the current KWave.
    outstanding_t gemm_count_q [2];

    count_t load_wave_q;
    count_t load_a_q, load_b_q;
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
    logic next_load_base_group_q, next_acc_group_q;

    function automatic count_t ceil_div(input logic [DIM_WIDTH-1:0] v, input int d);
        return (count_t'(v) + count_t'(d - 1)) / count_t'(d);
    endfunction

    function automatic count_t min_count(input count_t v, input int limit);
        if (v > count_t'(limit)) return count_t'(limit);
        return v;
    endfunction

    // Address offsets are expressed in tiles.  Widen each count before any
    // arithmetic so products cannot overflow count_t before reaching the
    // ADDR_WIDTH-wide memory address.
    function automatic logic [ADDR_WIDTH-1:0] addr_count(input count_t v);
        return ADDR_WIDTH'(v);
    endfunction

    function automatic count_t choose_block_m(input count_t remaining_m,
                                               input count_t remaining_n);
        int best_m, best_n, best_area, best_balance, area, balance;
        begin
            best_m = 1; best_n = 1; best_area = 0; best_balance = 1 << 30;
            for (int cm = 1; cm <= A_GROUP; cm++) begin
                for (int cn = 1; cn <= B_GROUP; cn++) begin
                    if ((cm <= int'(remaining_m)) && (cn <= int'(remaining_n))) begin
                        area = cm * cn;
                        balance = (cm >= cn) ? cm - cn : cn - cm;
                        if ((area <= BLOCK_CAP) &&
                            ((area > best_area) ||
                             ((area == best_area) && (balance < best_balance)) ||
                             ((area == best_area) && (balance == best_balance) &&
                              (cm > best_m)))) begin
                            best_m = cm; best_n = cn; best_area = area;
                            best_balance = balance;
                        end
                    end
                end
            end
            return count_t'(best_m);
        end
    endfunction

    function automatic count_t choose_block_n(input count_t remaining_m,
                                               input count_t remaining_n);
        int best_m, best_n, best_area, best_balance, area, balance;
        begin
            best_m = 1; best_n = 1; best_area = 0; best_balance = 1 << 30;
            for (int cm = 1; cm <= A_GROUP; cm++) begin
                for (int cn = 1; cn <= B_GROUP; cn++) begin
                    if ((cm <= int'(remaining_m)) && (cn <= int'(remaining_n))) begin
                        area = cm * cn;
                        balance = (cm >= cn) ? cm - cn : cn - cm;
                        if ((area <= BLOCK_CAP) &&
                            ((area > best_area) ||
                             ((area == best_area) && (balance < best_balance)) ||
                             ((area == best_area) && (balance == best_balance) &&
                              (cm > best_m)))) begin
                            best_m = cm; best_n = cn; best_area = area;
                            best_balance = balance;
                        end
                    end
                end
            end
            return count_t'(best_n);
        end
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
        input count_t tile, input logic [DIM_WIDTH-1:0] dim);
        count_t left;
        begin
            if (count_t'(dim) <= tile * count_t'(SA_WIDTH)) return '0;
            left = count_t'(dim) - tile * count_t'(SA_WIDTH);
            if (left > count_t'(SA_WIDTH)) return LOAD_ROWS_WIDTH'(SA_WIDTH);
            return LOAD_ROWS_WIDTH'(left);
        end
    endfunction

    function automatic count_t flat_batch(input count_t flat);
        return flat / (tm_q * tn_q);
    endfunction
    function automatic count_t flat_in_batch(input count_t flat);
        return flat % (tm_q * tn_q);
    endfunction
    function automatic count_t flat_m(input count_t flat);
        return flat_in_batch(flat) / tn_q;
    endfunction
    function automatic count_t flat_n(input count_t flat);
        return flat_in_batch(flat) % tn_q;
    endfunction

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
        next_exists_q && gemm_sent_q && ((tk_q <= 1) || load_ready_q);

    // Next-block descriptor calculation.  The parser walks N blocks first,
    // then M blocks, then batches; merge mode walks a flat batch-tile list.
    logic next_exists_comb;
    count_t next_bm_comb, next_bn_comb, next_batch_idx_comb;
    count_t next_mbase_comb, next_nbase_comb;
    count_t next_merge_base_comb, next_merge_count_comb;
    always_comb begin
        next_exists_comb = 1'b0;
        next_bm_comb = bm_q; next_bn_comb = bn_q;
        next_batch_idx_comb = batch_idx_q;
        next_mbase_comb = block_m_base_q; next_nbase_comb = block_n_base_q;
        next_merge_base_comb = merge_base_q;
        next_merge_count_comb = merge_count_q;

        if (merge_mode_q) begin
            if (merge_base_q + merge_count_q < count_t'(batch_q) * tm_q * tn_q) begin
                next_exists_comb = 1'b1;
                next_merge_base_comb = merge_base_q + merge_count_q;
                next_merge_count_comb = min_count(
                    count_t'(batch_q) * tm_q * tn_q - merge_base_q - merge_count_q,
                    MERGE_CAP);
            end
        end else if (block_n_base_q + bn_q < tn_q) begin
            next_exists_comb = 1'b1;
            next_nbase_comb = block_n_base_q + bn_q;
            next_bn_comb = choose_block_n(tm_q - block_m_base_q,
                                          tn_q - next_nbase_comb);
        end else if (block_m_base_q + bm_q < tm_q) begin
            next_exists_comb = 1'b1;
            next_mbase_comb = block_m_base_q + bm_q;
            next_nbase_comb = 0;
            next_bm_comb = choose_block_m(tm_q - next_mbase_comb, tn_q);
            next_bn_comb = choose_block_n(tm_q - next_mbase_comb, tn_q);
        end else if (batch_idx_q + 1 < batch_q) begin
            next_exists_comb = 1'b1;
            next_batch_idx_comb = batch_idx_q + 1'b1;
            next_mbase_comb = 0;
            next_nbase_comb = 0;
            next_bm_comb = choose_block_m(tm_q, tn_q);
            next_bn_comb = choose_block_n(tm_q, tn_q);
        end
    end

    logic load_from_next_comb, load_next_exists_comb;
    count_t load_bm_comb, load_bn_comb, load_batch_comb;
    count_t load_mbase_comb, load_nbase_comb, load_merge_base_comb, load_merge_count_comb;
    logic load_group_comb;
    always_comb begin
        load_from_next_comb = (state_q == OUTPUT_PRELOAD) ||
            ((state_q == WAVE) && (gemm_wave_q + 1 >= tk_q));
        load_next_exists_comb = (state_q == OUTPUT_PRELOAD) ?
            next_exists_q : next_exists_comb;
        if (state_q == OUTPUT_PRELOAD) begin
            load_bm_comb = next_bm_q;
            load_bn_comb = next_bn_q;
            load_batch_comb = next_batch_idx_q;
            load_mbase_comb = next_block_m_base_q;
            load_nbase_comb = next_block_n_base_q;
            load_merge_base_comb = next_merge_base_q;
            load_merge_count_comb = next_merge_count_q;
            load_group_comb = next_load_base_group_q;
        end else if (load_from_next_comb) begin
            load_bm_comb = next_bm_comb;
            load_bn_comb = next_bn_comb;
            load_batch_comb = next_batch_idx_comb;
            load_mbase_comb = next_mbase_comb;
            load_nbase_comb = next_nbase_comb;
            load_merge_base_comb = next_merge_base_comb;
            load_merge_count_comb = next_merge_count_comb;
            // wave 0 of the next block is written opposite the final GEMM's
            // operand half, independent of whether TK is odd or even.
            load_group_comb = ~(load_base_group_q ^ ~tk_q[0]);
        end else begin
            load_bm_comb = bm_q;
            load_bn_comb = bn_q;
            load_batch_comb = batch_idx_q;
            load_mbase_comb = block_m_base_q;
            load_nbase_comb = block_n_base_q;
            load_merge_base_comb = merge_base_q;
            load_merge_count_comb = merge_count_q;
            load_group_comb = load_base_group_q;
        end
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
        gemm_acc_group_comb = gemm_from_next_comb ? next_acc_group_q : acc_group_q;
    end

    always_comb begin
        load_valid_o = 1'b0;
        load_is_b_o = 1'b0;
        load_group_o = load_group_comb ^ load_wave_q[0];
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
            if (load_a_q < (load_from_next_comb ?
                            (merge_mode_q ? load_merge_count_comb : load_bm_comb) :
                            (merge_mode_q ? merge_count_q : bm_q))) begin
                load_valid_o = 1'b1;
                load_is_b_o = 1'b0;
                if (merge_mode_q) begin
                    load_addr_o = a_base_q +
                        addr_count(flat_batch(load_merge_base_comb + load_a_q)) *
                        addr_count(tm_q) * addr_count(tk_q) +
                        addr_count(flat_m(load_merge_base_comb + load_a_q)) *
                        addr_count(tk_q) + addr_count(load_wave_q);
                    load_abufidx_o = abuf_slot(load_group_o, load_a_q);
                    load_valid_rows_o = valid_rows(
                        flat_m(load_merge_base_comb + load_a_q), m_q);
                end else begin
                    load_addr_o = a_base_q +
                        addr_count(load_batch_comb) * addr_count(tm_q) *
                        addr_count(tk_q) +
                        (addr_count(load_mbase_comb) + addr_count(load_a_q)) *
                        addr_count(tk_q) + addr_count(load_wave_q);
                    load_abufidx_o = abuf_slot(load_group_o, load_a_q);
                    load_valid_rows_o = valid_rows(load_mbase_comb + load_a_q, m_q);
                end
            end else if (load_b_q < (load_from_next_comb ?
                                     (merge_mode_q ? load_merge_count_comb : load_bn_comb) :
                                     (merge_mode_q ? merge_count_q : bn_q))) begin
                load_valid_o = 1'b1;
                load_is_b_o = 1'b1;
                if (merge_mode_q) begin
                    load_addr_o = b_base_q +
                        addr_count(flat_batch(load_merge_base_comb + load_b_q)) *
                        addr_count(tk_q) * addr_count(tn_q) +
                        addr_count(load_wave_q) * addr_count(tn_q) +
                        addr_count(flat_n(load_merge_base_comb + load_b_q));
                    load_bbufidx_o = bbuf_slot(load_group_o, load_b_q);
                    load_valid_rows_o = valid_rows(
                        flat_n(load_merge_base_comb + load_b_q), n_q);
                end else begin
                    load_addr_o = b_base_q +
                        addr_count(load_batch_comb) * addr_count(tk_q) *
                        addr_count(tn_q) +
                        addr_count(load_wave_q) * addr_count(tn_q) +
                        addr_count(load_nbase_comb) + addr_count(load_b_q);
                    load_bbufidx_o = bbuf_slot(load_group_o, load_b_q);
                    load_valid_rows_o = valid_rows(load_nbase_comb + load_b_q, n_q);
                end
            end
        end

        if (((state_q == WAVE) || gemm_from_next_comb) && !gemm_sent_q &&
            (merge_mode_q ? (gemm_m_q < gemm_merge_count_comb) :
             (gemm_m_q < gemm_bm_comb && gemm_n_q < gemm_bn_comb))) begin
            gemm_valid_o = 1'b1;
            gemm_abufidx_o = abuf_slot(gemm_group_o, gemm_m_q);
            gemm_bbufidx_o = bbuf_slot(gemm_group_o,
                merge_mode_q ? gemm_m_q : gemm_n_q);
            gemm_paccidx_o = pacc_slot(gemm_acc_group_comb,
                merge_mode_q ? gemm_m_q : gemm_m_q * gemm_bn_comb + gemm_n_q);
        end

        if (!output_issue_done_q && (gemm_count_q[0] == 0) &&
            (merge_mode_q ? (output_m_q < output_merge_count_q) :
             (output_m_q < output_bm_q && output_n_q < output_bn_q))) begin
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
            gemm_sent_q <= 1'b0;
            output_issue_done_q <= 1'b1;
            output_bm_q <= '0; output_bn_q <= '0;
            output_batch_idx_q <= '0;
            output_block_m_base_q <= '0; output_block_n_base_q <= '0;
            output_merge_base_q <= '0; output_merge_count_q <= '0;
            output_acc_group_q <= 1'b0;
            next_exists_q <= 1'b0;
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
                tm_q <= ceil_div(cmd_m_i, SA_WIDTH);
                tn_q <= ceil_div(cmd_n_i, SA_WIDTH);
                tk_q <= ceil_div(cmd_k_i, SUBTILE_K);
                bm_q <= choose_block_m(ceil_div(cmd_m_i, SA_WIDTH),
                                       ceil_div(cmd_n_i, SA_WIDTH));
                bn_q <= choose_block_n(ceil_div(cmd_m_i, SA_WIDTH),
                                       ceil_div(cmd_n_i, SA_WIDTH));
                batch_idx_q <= 0; block_m_base_q <= 0; block_n_base_q <= 0;
                merge_mode_q <= ceil_div(cmd_m_i, SA_WIDTH) *
                                ceil_div(cmd_n_i, SA_WIDTH) < count_t'(MERGE_CAP);
                merge_base_q <= 0;
                merge_count_q <= min_count(count_t'(cmd_batch_i) *
                    ceil_div(cmd_m_i, SA_WIDTH) * ceil_div(cmd_n_i, SA_WIDTH), MERGE_CAP);
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
                    if ((!load_is_b_o && load_a_q + 1 >=
                         (load_from_next_comb ? (merge_mode_q ? load_merge_count_comb : load_bm_comb) :
                                                 (merge_mode_q ? merge_count_q : bm_q)) &&
                         load_b_q >= (load_from_next_comb ? (merge_mode_q ? load_merge_count_comb : load_bn_comb) :
                                                               (merge_mode_q ? merge_count_q : bn_q))) ||
                        (load_is_b_o && load_b_q + 1 >=
                         (load_from_next_comb ? (merge_mode_q ? load_merge_count_comb : load_bn_comb) :
                                                 (merge_mode_q ? merge_count_q : bn_q)) &&
                         load_a_q >= (load_from_next_comb ? (merge_mode_q ? load_merge_count_comb : load_bm_comb) :
                                                               (merge_mode_q ? merge_count_q : bm_q)))) begin
                        load_issue_done_q <= 1'b1;
                    end
                end

                if (gemm_fire) begin
                    gemm_sent_q <= merge_mode_q ?
                        (gemm_m_q + 1 >= gemm_merge_count_comb) :
                        ((gemm_m_q + 1 >= gemm_bm_comb) &&
                         (gemm_n_q + 1 >= gemm_bn_comb));
                    if (merge_mode_q || gemm_n_q + 1 >= gemm_bn_comb) begin
                        gemm_m_q <= gemm_m_q + 1'b1; gemm_n_q <= 0;
                    end else gemm_n_q <= gemm_n_q + 1'b1;
                end
                if (output_fire) begin
                    if (merge_mode_q || output_n_q + 1 >= output_bn_q) begin
                        output_m_q <= output_m_q + 1'b1; output_n_q <= 0;
                    end else output_n_q <= output_n_q + 1'b1;
                    if ((!merge_mode_q && output_m_q + 1 >= output_bm_q &&
                         output_n_q + 1 >= output_bn_q) ||
                        (merge_mode_q &&
                         output_m_q + 1 >= output_merge_count_q))
                        output_issue_done_q <= 1'b1;
                end
                if ((state_q == PRELOAD) && load_issue_done_q && load_count_q == 0) begin
                    gemm_wave_q <= 0; gemm_m_q <= 0; gemm_n_q <= 0;
                    gemm_sent_q <= 1'b0;
                    load_ready_q <= 1'b0;
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
                        next_load_base_group_q <= load_group_comb;
                        next_acc_group_q <= ~acc_group_q;
                        // PACC ownership changes at KWave advance.  OUTPUT uses
                        // the separately captured old-half descriptor above.
                        acc_group_q <= ~acc_group_q;
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
                    merge_base_q <= next_merge_base_q;
                    merge_count_q <= next_merge_count_q;
                    load_base_group_q <= next_load_base_group_q;
                    acc_group_q <= next_acc_group_q;
                    load_ready_q <= 1'b0;
                    load_a_q <= 0; load_b_q <= 0;
                    load_issue_done_q <= 1'b0;
                    if (tk_q > 1) begin
                        gemm_wave_q <= 1;
                        gemm_m_q <= 0; gemm_n_q <= 0;
                        gemm_sent_q <= 1'b0;
                        if (tk_q > 2) load_wave_q <= 2;
                        else load_wave_q <= 0;
                        load_active_q <= 1'b1; load_issue_done_q <= 1'b0;
                    end else begin
                        // wave 0 was already executed in this boundary group;
                        // WAVE now represents its completed final K-wave while
                        // preloading the block after it, if one exists.
                        gemm_wave_q <= 0;
                        gemm_m_q <= 0; gemm_n_q <= 0;
                        gemm_sent_q <= 1'b1;
                        load_wave_q <= 0;
                        load_active_q <= 1'b1;
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
        if (SUBTILE_K <= 0 || (SUBTILE_K & (SUBTILE_K - 1)) != 0)
            $error("SUBTILE_K must be a positive power of two");
        if (ABUF_SIZE < 2 || BBUF_SIZE < 2 || PACC_NUM < 2 ||
            (ABUF_SIZE & 1) != 0 || (BBUF_SIZE & 1) != 0 || (PACC_NUM & 1) != 0)
            $error("buffers and PACC must have two even ping-pong halves");
    end
endmodule

`default_nettype wire
