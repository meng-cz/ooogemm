// Dynamic scheduler for renamed LOAD/GEMM/OUTPUT uops.
//
// LOAD uops retain dispatch order in one FIFO.  GEMMs are partitioned by their
// physical PACC tag into FIFO issue slots; this keeps same-ACC operations in
// dispatch order while a round-robin arbiter selects a ready head from
// different slots.  A dispatched GEMM leaves its slot immediately: the array
// guarantees that uops dispatched in slot order also complete in that order.
// OUTPUT is held as one pending record per PACC and issues only after all GEMM
// uops using that PACC have completed.

`default_nettype none

module dynamic_sche #(
    parameter int ABUF_PHYS_SIZE = 16,
    parameter int BBUF_PHYS_SIZE = 16,
    parameter int PACC_PHYS_SIZE = 16,
    parameter int ADDR_WIDTH = 32,
    parameter int LOAD_ROWS_WIDTH = 6,
    parameter int LOAD_QUEUE_DEPTH = 16,
    parameter int GEMM_SLOT_DEPTH = 16,
    // Keep fine-grain PACC parallelism for small arrays, then reduce slot
    // count as the PACC file grows.  The value remains overrideable.
    parameter int SLOT_ACC_COUNT = (PACC_PHYS_SIZE <= 16) ? 1 :
                                   (PACC_PHYS_SIZE <= 32) ? 2 : 4,
    parameter int ABUF_PHYS_IDX_WIDTH =
        (ABUF_PHYS_SIZE <= 1) ? 1 : $clog2(ABUF_PHYS_SIZE),
    parameter int BBUF_PHYS_IDX_WIDTH =
        (BBUF_PHYS_SIZE <= 1) ? 1 : $clog2(BBUF_PHYS_SIZE),
    parameter int PACC_PHYS_IDX_WIDTH =
        (PACC_PHYS_SIZE <= 1) ? 1 : $clog2(PACC_PHYS_SIZE),
    parameter int USE_COUNT_WIDTH = 16,
    parameter int SLOT_COUNT = (PACC_PHYS_SIZE + SLOT_ACC_COUNT - 1) / SLOT_ACC_COUNT,
    parameter int LOAD_PTR_WIDTH = (LOAD_QUEUE_DEPTH <= 1) ? 1 : $clog2(LOAD_QUEUE_DEPTH),
    parameter int GEMM_PTR_WIDTH = (GEMM_SLOT_DEPTH <= 1) ? 1 : $clog2(GEMM_SLOT_DEPTH),
    parameter int SLOT_IDX_WIDTH = (SLOT_COUNT <= 1) ? 1 : $clog2(SLOT_COUNT)
) (
    input logic clk,
    input logic rst_n,

    // Renamed uop input.
    input logic uop_valid_i,
    output logic uop_ready_o,
    input uopparse_pkg::uop_type_e uop_type_i,
    input logic [ADDR_WIDTH-1:0] uop_addr_i,
    input logic [ABUF_PHYS_IDX_WIDTH-1:0] uop_abufidx_i,
    input logic [BBUF_PHYS_IDX_WIDTH-1:0] uop_bbufidx_i,
    input logic [PACC_PHYS_IDX_WIDTH-1:0] uop_paccidx_i,
    input logic [LOAD_ROWS_WIDTH-1:0] uop_valid_rows_i,
    input logic uop_accum_i,

    // Ordered LOAD issue port.
    output logic load_valid_o,
    input logic load_ready_i,
    output uopparse_pkg::uop_type_e load_type_o,
    output logic [ADDR_WIDTH-1:0] load_addr_o,
    output logic [ABUF_PHYS_IDX_WIDTH-1:0] load_abufidx_o,
    output logic [BBUF_PHYS_IDX_WIDTH-1:0] load_bbufidx_o,
    output logic [LOAD_ROWS_WIDTH-1:0] load_valid_rows_o,

    // Out-of-order GEMM issue port.
    output logic gemm_valid_o,
    input logic gemm_ready_i,
    output logic [ABUF_PHYS_IDX_WIDTH-1:0] gemm_abufidx_o,
    output logic [BBUF_PHYS_IDX_WIDTH-1:0] gemm_bbufidx_o,
    output logic [PACC_PHYS_IDX_WIDTH-1:0] gemm_paccidx_o,
    output logic gemm_accum_o,

    // OUTPUT issue port.
    output logic output_valid_o,
    input logic output_ready_i,
    output logic [ADDR_WIDTH-1:0] output_addr_o,
    output logic [PACC_PHYS_IDX_WIDTH-1:0] output_paccidx_o,

    // Wakeup/completion feedback.  Each feedback takes effect after the edge.
    input logic load_a_done_valid_i,
    input logic [ABUF_PHYS_IDX_WIDTH-1:0] load_a_done_phys_i,
    input logic load_b_done_valid_i,
    input logic [BBUF_PHYS_IDX_WIDTH-1:0] load_b_done_phys_i,
    input logic gemm_done_valid_i,
    input logic [PACC_PHYS_IDX_WIDTH-1:0] gemm_done_paccidx_i,
    input logic output_done_valid_i,
    input logic [PACC_PHYS_IDX_WIDTH-1:0] output_done_paccidx_i
);

    import uopparse_pkg::*;

    typedef logic [USE_COUNT_WIDTH-1:0] use_count_t;
    typedef struct packed {
        uop_type_e typ;
        logic [ADDR_WIDTH-1:0] addr;
        logic [ABUF_PHYS_IDX_WIDTH-1:0] abuf;
        logic [BBUF_PHYS_IDX_WIDTH-1:0] bbuf;
        logic [LOAD_ROWS_WIDTH-1:0] valid_rows;
    } load_uop_t;
    typedef struct packed {
        logic [ABUF_PHYS_IDX_WIDTH-1:0] abuf;
        logic [BBUF_PHYS_IDX_WIDTH-1:0] bbuf;
        logic [PACC_PHYS_IDX_WIDTH-1:0] pacc;
        logic accum;
    } gemm_uop_t;

    load_uop_t load_q [LOAD_QUEUE_DEPTH];
    logic [LOAD_PTR_WIDTH-1:0] load_rd_q, load_wr_q;
    logic [$clog2(LOAD_QUEUE_DEPTH + 1)-1:0] load_count_q;
    gemm_uop_t gemm_q [SLOT_COUNT][GEMM_SLOT_DEPTH];
    logic [GEMM_PTR_WIDTH-1:0] gemm_rd_q [SLOT_COUNT];
    // Registered operand indices of the current queue head.  They mirror
    // gemm_q[s][gemm_rd_q[s]] and keep the head read mux (whose select nets
    // fan out over the whole queue) out of the slot-ready decision path.
    logic [ABUF_PHYS_IDX_WIDTH-1:0] head_abuf_q [SLOT_COUNT];
    logic [BBUF_PHYS_IDX_WIDTH-1:0] head_bbuf_q [SLOT_COUNT];
    logic [GEMM_PTR_WIDTH-1:0] gemm_wr_q [SLOT_COUNT];
    logic [$clog2(GEMM_SLOT_DEPTH + 1)-1:0] gemm_count_q [SLOT_COUNT];
    logic gemm_buf_valid_q [SLOT_COUNT];
    gemm_uop_t gemm_buf_q [SLOT_COUNT];
    logic [SLOT_IDX_WIDTH-1:0] gemm_rr_q;

    logic abuf_ready_q [ABUF_PHYS_SIZE];
    logic bbuf_ready_q [BBUF_PHYS_SIZE];
    logic acc_ready_q [PACC_PHYS_SIZE];
    use_count_t acc_use_count_q [PACC_PHYS_SIZE];
    logic output_pending_q [PACC_PHYS_SIZE];
    logic output_issued_q [PACC_PHYS_SIZE];
    logic [ADDR_WIDTH-1:0] output_addr_q [PACC_PHYS_SIZE];
    logic [PACC_PHYS_IDX_WIDTH-1:0] output_rr_q;

    logic selected_gemm_valid;
    logic [SLOT_IDX_WIDTH-1:0] selected_gemm_slot;
    gemm_uop_t selected_gemm;
    logic selected_output_valid;
    logic [PACC_PHYS_IDX_WIDTH-1:0] selected_output_pacc;
    logic [PACC_PHYS_SIZE-1:0] output_eligible;
    logic [PACC_PHYS_SIZE-1:0] output_at_or_above_rr;
    logic [PACC_PHYS_SIZE-1:0] output_eligible_high;
    logic [PACC_PHYS_SIZE-1:0] output_select_onehot;
    logic output_eligible_high_valid;
    logic [SLOT_COUNT-1:0] gemm_slot_valid;
    logic [SLOT_COUNT-1:0] gemm_slot_at_or_above_rr;
    logic [SLOT_COUNT-1:0] gemm_slot_valid_high;
    logic [SLOT_COUNT-1:0] gemm_slot_select_onehot;
    logic gemm_slot_valid_high_valid;
    logic input_pacc_in_range;
    logic input_abuf_in_range;
    logic input_bbuf_in_range;
    logic input_slot_in_range;
    logic [SLOT_IDX_WIDTH-1:0] input_slot;
    logic load_fire, gemm_fire, output_fire, input_fire;

    localparam int SLOT_ACC_SHIFT = $clog2(SLOT_ACC_COUNT);

    // Round-robin arbitration needs "least significant set bit" of a rotated
    // ready bitmap and a one-hot to binary re-encoding.  Both are written as
    // explicit balanced networks: a log-depth prefix OR replaces the
    // "value & (~value + 1)" form (whose wide incrementer mapped to a long
    // carry chain), and each index bit is a masked OR reduction instead of an
    // accumulating OR chain that a synthesizer may keep serial.
    function automatic logic [PACC_PHYS_SIZE-1:0] output_lowest_bit(
        input logic [PACC_PHYS_SIZE-1:0] value
    );
        logic [PACC_PHYS_SIZE-1:0] prefix;
        logic [PACC_PHYS_SIZE-1:0] lower_any;
        logic [PACC_PHYS_SIZE-1:0] tmp;
        begin
            prefix = value;
            for (int step = 1; step < PACC_PHYS_SIZE; step <<= 1) begin
                for (int i = 0; i < PACC_PHYS_SIZE; i++) begin
                    tmp[i] = (i >= step) ? (prefix[i] | prefix[i - step])
                                         : prefix[i];
                end
                prefix = tmp;
            end
            for (int i = 0; i < PACC_PHYS_SIZE; i++) begin
                lower_any[i] = (i == 0) ? 1'b0 : prefix[i - 1];
            end
            return value & ~lower_any;
        end
    endfunction

    function automatic logic [PACC_PHYS_IDX_WIDTH-1:0] output_index_encode(
        input logic [PACC_PHYS_SIZE-1:0] onehot
    );
        logic [PACC_PHYS_SIZE-1:0] terms [PACC_PHYS_IDX_WIDTH];
        logic [PACC_PHYS_IDX_WIDTH-1:0] index;
        begin
            for (int bit_pos = 0; bit_pos < PACC_PHYS_IDX_WIDTH; bit_pos++) begin
                terms[bit_pos] = '0;
                for (int idx = 0; idx < PACC_PHYS_SIZE; idx++) begin
                    if (((idx >> bit_pos) & 1) != 0) begin
                        terms[bit_pos][idx] = onehot[idx];
                    end
                end
                index[bit_pos] = |terms[bit_pos];
            end
            return index;
        end
    endfunction

    function automatic logic [SLOT_COUNT-1:0] gemm_slot_lowest_bit(
        input logic [SLOT_COUNT-1:0] value
    );
        logic [SLOT_COUNT-1:0] prefix;
        logic [SLOT_COUNT-1:0] lower_any;
        logic [SLOT_COUNT-1:0] tmp;
        begin
            prefix = value;
            for (int step = 1; step < SLOT_COUNT; step <<= 1) begin
                for (int i = 0; i < SLOT_COUNT; i++) begin
                    tmp[i] = (i >= step) ? (prefix[i] | prefix[i - step])
                                         : prefix[i];
                end
                prefix = tmp;
            end
            for (int i = 0; i < SLOT_COUNT; i++) begin
                lower_any[i] = (i == 0) ? 1'b0 : prefix[i - 1];
            end
            return value & ~lower_any;
        end
    endfunction

    function automatic logic [SLOT_IDX_WIDTH-1:0] gemm_slot_index_encode(
        input logic [SLOT_COUNT-1:0] onehot
    );
        logic [SLOT_COUNT-1:0] terms [SLOT_IDX_WIDTH];
        logic [SLOT_IDX_WIDTH-1:0] index;
        begin
            for (int bit_pos = 0; bit_pos < SLOT_IDX_WIDTH; bit_pos++) begin
                terms[bit_pos] = '0;
                for (int idx = 0; idx < SLOT_COUNT; idx++) begin
                    if (((idx >> bit_pos) & 1) != 0) begin
                        terms[bit_pos][idx] = onehot[idx];
                    end
                end
                index[bit_pos] = |terms[bit_pos];
            end
            return index;
        end
    endfunction

    function automatic logic [LOAD_PTR_WIDTH-1:0] load_inc(
        input logic [LOAD_PTR_WIDTH-1:0] ptr
    );
        if (int'(ptr) == LOAD_QUEUE_DEPTH - 1) begin
            return '0;
        end
        return ptr + 1'b1;
    endfunction

    function automatic logic [GEMM_PTR_WIDTH-1:0] gemm_inc(
        input logic [GEMM_PTR_WIDTH-1:0] ptr
    );
        if (int'(ptr) == GEMM_SLOT_DEPTH - 1) begin
            return '0;
        end
        return ptr + 1'b1;
    endfunction

    always_comb begin
        input_pacc_in_range = int'(uop_paccidx_i) < PACC_PHYS_SIZE;
        input_abuf_in_range = int'(uop_abufidx_i) < ABUF_PHYS_SIZE;
        input_bbuf_in_range = int'(uop_bbufidx_i) < BBUF_PHYS_SIZE;
        // SLOT_ACC_COUNT is a power of two, so the slot is just the upper
        // portion of the PACC index.  This avoids a serial boundary decoder.
        input_slot = SLOT_IDX_WIDTH'(uop_paccidx_i >> SLOT_ACC_SHIFT);
        input_slot_in_range = int'(input_slot) < SLOT_COUNT;

        uop_ready_o = 1'b0;
        unique case (uop_type_i)
            UOP_LOAD_A: uop_ready_o = input_abuf_in_range &&
                (int'(load_count_q) < LOAD_QUEUE_DEPTH);
            UOP_LOAD_B: uop_ready_o = input_bbuf_in_range &&
                (int'(load_count_q) < LOAD_QUEUE_DEPTH);
            UOP_GEMM: uop_ready_o = input_abuf_in_range && input_bbuf_in_range &&
                input_pacc_in_range && input_slot_in_range &&
                (int'(gemm_count_q[int'(input_slot)]) < GEMM_SLOT_DEPTH);
            UOP_OUTPUT: uop_ready_o = input_pacc_in_range &&
                !output_pending_q[int'(uop_paccidx_i)];
            default: uop_ready_o = 1'b0;
        endcase
    end

    assign input_fire = uop_valid_i && uop_ready_o;

    always_comb begin
        load_valid_o = (load_count_q != '0);
        load_type_o = UOP_LOAD_A;
        load_addr_o = '0;
        load_abufidx_o = '0;
        load_bbufidx_o = '0;
        load_valid_rows_o = '0;
        if (load_count_q != '0) begin
            load_type_o = load_q[int'(load_rd_q)].typ;
            load_addr_o = load_q[int'(load_rd_q)].addr;
            load_abufidx_o = load_q[int'(load_rd_q)].abuf;
            load_bbufidx_o = load_q[int'(load_rd_q)].bbuf;
            load_valid_rows_o = load_q[int'(load_rd_q)].valid_rows;
        end
    end
    assign load_fire = load_valid_o && load_ready_i;

    // Rotate the valid bitmap so bit zero is the round-robin start, isolate
    // the least-significant set bit, then OR-encode its index.  This gives the
    // synthesizer a structured arithmetic/OR network instead of the explicit
    // serial priority chain produced by "!selected_valid" in a loop.
    always_comb begin
        for (int slot_idx = 0; slot_idx < SLOT_COUNT; slot_idx++) begin
            gemm_slot_valid[slot_idx] = gemm_buf_valid_q[slot_idx];
        end
        // Keep the bitmap in place and mask off the slots below the
        // round-robin pointer: the winner is the lowest set bit at or above
        // the pointer, or - only when that half is empty - the lowest set bit
        // of the whole bitmap.  This removes both the wide barrel rotate and
        // the final "pointer + offset" modulo add from the arbiter.
        for (int slot_idx = 0; slot_idx < SLOT_COUNT; slot_idx++) begin
            gemm_slot_at_or_above_rr[slot_idx] =
                (slot_idx >= int'(gemm_rr_q));
        end
        gemm_slot_valid_high = gemm_slot_valid & gemm_slot_at_or_above_rr;
        gemm_slot_valid_high_valid = |gemm_slot_valid_high;
        gemm_slot_select_onehot = gemm_slot_lowest_bit(
            gemm_slot_valid_high_valid ? gemm_slot_valid_high
                                       : gemm_slot_valid);
        selected_gemm_valid = |gemm_slot_valid;
        selected_gemm_slot = gemm_slot_index_encode(gemm_slot_select_onehot);
        selected_gemm = selected_gemm_valid ?
            gemm_buf_q[int'(selected_gemm_slot)] : '0;
    end
    assign gemm_valid_o = selected_gemm_valid;
    assign gemm_abufidx_o = selected_gemm.abuf;
    assign gemm_bbufidx_o = selected_gemm.bbuf;
    assign gemm_paccidx_o = selected_gemm.pacc;
    assign gemm_accum_o = selected_gemm.accum;
    assign gemm_fire = gemm_valid_o && gemm_ready_i;

    always_comb begin
        for (int pacc = 0; pacc < PACC_PHYS_SIZE; pacc++) begin
            output_eligible[pacc] = output_pending_q[pacc] &&
                !output_issued_q[pacc] && (acc_use_count_q[pacc] == '0) &&
                acc_ready_q[pacc];
        end

        // Same masked round-robin as the GEMM slot arbiter: the encoded
        // one-hot index is the PACC index directly, so no rotate and no
        // pointer-add are needed.
        for (int pacc_idx = 0; pacc_idx < PACC_PHYS_SIZE; pacc_idx++) begin
            output_at_or_above_rr[pacc_idx] =
                (pacc_idx >= int'(output_rr_q));
        end
        output_eligible_high = output_eligible & output_at_or_above_rr;
        output_eligible_high_valid = |output_eligible_high;
        output_select_onehot = output_lowest_bit(
            output_eligible_high_valid ? output_eligible_high
                                       : output_eligible);
        selected_output_valid = |output_eligible;
        selected_output_pacc = output_index_encode(output_select_onehot);
    end
    assign output_valid_o = selected_output_valid;
    assign output_paccidx_o = selected_output_pacc;
    assign output_addr_o = selected_output_valid ?
        output_addr_q[int'(selected_output_pacc)] : '0;
    assign output_fire = output_valid_o && output_ready_i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_rd_q <= '0;
            load_wr_q <= '0;
            load_count_q <= '0;
            gemm_rr_q <= '0;
            output_rr_q <= '0;
            for (int s = 0; s < SLOT_COUNT; s++) begin
                gemm_rd_q[s] <= '0;
                gemm_wr_q[s] <= '0;
                head_abuf_q[s] <= '0;
                head_bbuf_q[s] <= '0;
                gemm_count_q[s] <= '0;
                gemm_buf_valid_q[s] <= 1'b0;
                gemm_buf_q[s] <= '0;
            end
            for (int p = 0; p < ABUF_PHYS_SIZE; p++) begin
                abuf_ready_q[p] <= 1'b0;
            end
            for (int p = 0; p < BBUF_PHYS_SIZE; p++) begin
                bbuf_ready_q[p] <= 1'b0;
            end
            for (int p = 0; p < PACC_PHYS_SIZE; p++) begin
                acc_ready_q[p] <= 1'b0;
                acc_use_count_q[p] <= '0;
                output_pending_q[p] <= 1'b0;
                output_issued_q[p] <= 1'b0;
                output_addr_q[p] <= '0;
            end
        end else begin
            // LOAD queue enqueue/dequeue can occur together.
            if (load_fire) begin
                load_rd_q <= load_inc(load_rd_q);
            end
            if (input_fire && ((uop_type_i == UOP_LOAD_A) || (uop_type_i == UOP_LOAD_B))) begin
                load_q[int'(load_wr_q)] <= '{
                    typ: uop_type_i, addr: uop_addr_i, abuf: uop_abufidx_i,
                    bbuf: uop_bbufidx_i, valid_rows: uop_valid_rows_i};
                load_wr_q <= load_inc(load_wr_q);
            end
            unique case ({(input_fire && ((uop_type_i == UOP_LOAD_A) ||
                                           (uop_type_i == UOP_LOAD_B))), load_fire})
                2'b10: load_count_q <= load_count_q + 1'b1;
                2'b01: load_count_q <= load_count_q - 1'b1;
                default: begin end
            endcase

            // A ready FIFO head enters its slot pipeline register only when
            // that register is empty.  The arbiter sees only registered heads,
            // so a fill cannot be issued until the following cycle.
            for (int s = 0; s < SLOT_COUNT; s++) begin
                logic enqueue_here;
                logic fill_here;
                gemm_uop_t head;
                enqueue_here = input_fire && (uop_type_i == UOP_GEMM) &&
                    (int'(input_slot) == s);
                head = gemm_q[s][int'(gemm_rd_q[s])];
                fill_here = !gemm_buf_valid_q[s] && (gemm_count_q[s] != '0) &&
                    abuf_ready_q[int'(head_abuf_q[s])] &&
                    bbuf_ready_q[int'(head_bbuf_q[s])];
                if (enqueue_here) begin
                    gemm_q[s][int'(gemm_wr_q[s])] <= '{
                        abuf: uop_abufidx_i, bbuf: uop_bbufidx_i,
                        pacc: uop_paccidx_i, accum: uop_accum_i};
                    gemm_wr_q[s] <= gemm_inc(gemm_wr_q[s]);
                end
                if (fill_here) begin
                    gemm_rd_q[s] <= gemm_inc(gemm_rd_q[s]);
                    gemm_buf_q[s] <= head;
                    gemm_buf_valid_q[s] <= 1'b1;
                    // The new head is the next queue entry, except when this
                    // cycle also enqueues into a slot that held exactly one
                    // entry: then the write lands exactly on the next head.
                    if (enqueue_here &&
                        (gemm_count_q[s] == $clog2(GEMM_SLOT_DEPTH + 1)'(1))) begin
                        head_abuf_q[s] <= uop_abufidx_i;
                        head_bbuf_q[s] <= uop_bbufidx_i;
                    end else begin
                        head_abuf_q[s] <=
                            gemm_q[s][int'(gemm_inc(gemm_rd_q[s]))].abuf;
                        head_bbuf_q[s] <=
                            gemm_q[s][int'(gemm_inc(gemm_rd_q[s]))].bbuf;
                    end
                end else if (enqueue_here && (gemm_count_q[s] == '0)) begin
                    // First entry of an empty queue becomes its head.
                    head_abuf_q[s] <= uop_abufidx_i;
                    head_bbuf_q[s] <= uop_bbufidx_i;
                end
                if (gemm_fire && (int'(selected_gemm_slot) == s)) begin
                    gemm_buf_valid_q[s] <= 1'b0;
                end
                unique case ({enqueue_here, fill_here})
                    2'b10: gemm_count_q[s] <= gemm_count_q[s] + 1'b1;
                    2'b01: gemm_count_q[s] <= gemm_count_q[s] - 1'b1;
                    default: begin end
                endcase
            end
            if (gemm_fire) begin
                if (int'(selected_gemm_slot) == SLOT_COUNT - 1) begin
                    gemm_rr_q <= '0;
                end else begin
                    gemm_rr_q <= selected_gemm_slot + 1'b1;
                end
            end

            // LOAD dispatch starts a new physical version; completion wakes
            // every GEMM slot observing that physical operand.
            if (load_a_done_valid_i && (int'(load_a_done_phys_i) < ABUF_PHYS_SIZE)) begin
                abuf_ready_q[int'(load_a_done_phys_i)] <= 1'b1;
            end
            if (load_b_done_valid_i && (int'(load_b_done_phys_i) < BBUF_PHYS_SIZE)) begin
                bbuf_ready_q[int'(load_b_done_phys_i)] <= 1'b1;
            end

            // Count all admitted GEMMs, not merely issued GEMMs, so OUTPUT
            // cannot bypass queued work.  ACC ready is for final OUTPUT only;
            // same-slot GEMMs may issue before prior GEMMs complete because
            // the systolic array preserves completion order for their ordered
            // dispatch stream.
            if (input_fire && (uop_type_i == UOP_GEMM) &&
                !(gemm_done_valid_i &&
                  (gemm_done_paccidx_i == uop_paccidx_i))) begin
                acc_use_count_q[int'(uop_paccidx_i)] <=
                    acc_use_count_q[int'(uop_paccidx_i)] + 1'b1;
            end
            if (gemm_done_valid_i && (int'(gemm_done_paccidx_i) < PACC_PHYS_SIZE)) begin
                if (!(input_fire && (uop_type_i == UOP_GEMM) &&
                      (gemm_done_paccidx_i == uop_paccidx_i)) &&
                    (acc_use_count_q[int'(gemm_done_paccidx_i)] != '0)) begin
                    acc_use_count_q[int'(gemm_done_paccidx_i)] <=
                        acc_use_count_q[int'(gemm_done_paccidx_i)] - 1'b1;
                end
                acc_ready_q[int'(gemm_done_paccidx_i)] <= 1'b1;
            end

            // A newly issued operation (or LOAD write) wins over a same-cycle
            // completion wakeup for the same physical destination.
            if (gemm_fire) begin
                acc_ready_q[int'(selected_gemm.pacc)] <= 1'b0;
            end
            if (load_fire && (load_type_o == UOP_LOAD_A)) begin
                abuf_ready_q[int'(load_abufidx_o)] <= 1'b0;
            end
            if (load_fire && (load_type_o == UOP_LOAD_B)) begin
                bbuf_ready_q[int'(load_bbufidx_o)] <= 1'b0;
            end

            if (input_fire && (uop_type_i == UOP_OUTPUT)) begin
                output_pending_q[int'(uop_paccidx_i)] <= 1'b1;
                output_issued_q[int'(uop_paccidx_i)] <= 1'b0;
                output_addr_q[int'(uop_paccidx_i)] <= uop_addr_i;
            end
            if (output_fire) begin
                output_issued_q[int'(selected_output_pacc)] <= 1'b1;
                if (int'(selected_output_pacc) == PACC_PHYS_SIZE - 1) begin
                    output_rr_q <= '0;
                end else begin
                    output_rr_q <= selected_output_pacc + 1'b1;
                end
            end
            if (output_done_valid_i && (int'(output_done_paccidx_i) < PACC_PHYS_SIZE)) begin
                output_pending_q[int'(output_done_paccidx_i)] <= 1'b0;
                output_issued_q[int'(output_done_paccidx_i)] <= 1'b0;
                output_addr_q[int'(output_done_paccidx_i)] <= '0;
            end
        end
    end

    initial begin
        if ((ABUF_PHYS_SIZE <= 0) || (BBUF_PHYS_SIZE <= 0) ||
            (PACC_PHYS_SIZE <= 0) || (LOAD_QUEUE_DEPTH <= 0) ||
            (GEMM_SLOT_DEPTH <= 0) || (SLOT_ACC_COUNT <= 0)) begin
            $error("dynamic_sche sizes must be positive");
        end
        if ((SLOT_ACC_COUNT & (SLOT_ACC_COUNT - 1)) != 0) begin
            $error("SLOT_ACC_COUNT must be a power of two");
        end
    end

`ifdef DYNAMIC_DEBUG
    integer debug_cycle;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            debug_cycle <= 0;
        end else begin
            debug_cycle <= debug_cycle + 1;
            if (input_fire && (uop_type_i == UOP_GEMM)) begin
                $display("DDBG in_gemm t=%0d pacc=%0d accum=%0d", debug_cycle,
                         uop_paccidx_i, uop_accum_i);
            end
            if (gemm_fire) begin
                $display("DDBG fire_gemm t=%0d pacc=%0d slot=%0d", debug_cycle,
                         selected_gemm.pacc, selected_gemm_slot);
            end
            if (gemm_done_valid_i) begin
                $display("DDBG done_gemm t=%0d pacc=%0d use=%0d", debug_cycle,
                         gemm_done_paccidx_i,
                         acc_use_count_q[int'(gemm_done_paccidx_i)]);
            end
            if (input_fire && (uop_type_i == UOP_OUTPUT)) begin
                $display("DDBG in_output t=%0d pacc=%0d", debug_cycle,
                         uop_paccidx_i);
            end
            if (output_fire) begin
                $display("DDBG fire_output t=%0d pacc=%0d", debug_cycle,
                         selected_output_pacc);
            end
            if (output_done_valid_i) begin
                $display("DDBG done_output t=%0d pacc=%0d", debug_cycle,
                         output_done_paccidx_i);
            end
        end
    end
`endif

endmodule

`default_nettype wire
