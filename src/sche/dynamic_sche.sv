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
    logic input_pacc_in_range;
    logic input_abuf_in_range;
    logic input_bbuf_in_range;
    logic input_slot_in_range;
    logic [SLOT_IDX_WIDTH-1:0] input_slot;
    logic load_fire, gemm_fire, output_fire, input_fire;

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
        input_slot = SLOT_IDX_WIDTH'(int'(uop_paccidx_i) / SLOT_ACC_COUNT);
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

    // A cheap rotating-priority scan gives each active slot service without a
    // full age matrix.  Only per-slot pipeline registers participate in
    // arbitration; a FIFO head reaches that register one cycle earlier.
    always_comb begin
        selected_gemm_valid = 1'b0;
        selected_gemm_slot = '0;
        selected_gemm = '0;
        for (int offset = 0; offset < SLOT_COUNT; offset++) begin
            logic [SLOT_IDX_WIDTH-1:0] slot;
            slot = SLOT_IDX_WIDTH'((int'(gemm_rr_q) + offset) % SLOT_COUNT);
            if (!selected_gemm_valid && gemm_buf_valid_q[slot]) begin
                selected_gemm_valid = 1'b1;
                selected_gemm_slot = SLOT_IDX_WIDTH'(slot);
                selected_gemm = gemm_buf_q[slot];
            end
        end
    end
    assign gemm_valid_o = selected_gemm_valid;
    assign gemm_abufidx_o = selected_gemm.abuf;
    assign gemm_bbufidx_o = selected_gemm.bbuf;
    assign gemm_paccidx_o = selected_gemm.pacc;
    assign gemm_accum_o = selected_gemm.accum;
    assign gemm_fire = gemm_valid_o && gemm_ready_i;

    always_comb begin
        selected_output_valid = 1'b0;
        selected_output_pacc = '0;
        for (int offset = 0; offset < PACC_PHYS_SIZE; offset++) begin
            logic [PACC_PHYS_IDX_WIDTH-1:0] pacc;
            pacc = PACC_PHYS_IDX_WIDTH'((int'(output_rr_q) + offset) % PACC_PHYS_SIZE);
            if (!selected_output_valid && output_pending_q[pacc] &&
                !output_issued_q[pacc] && (acc_use_count_q[pacc] == '0) &&
                acc_ready_q[pacc]) begin
                selected_output_valid = 1'b1;
                selected_output_pacc = PACC_PHYS_IDX_WIDTH'(pacc);
            end
        end
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
                    abuf_ready_q[int'(head.abuf)] && bbuf_ready_q[int'(head.bbuf)];
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
