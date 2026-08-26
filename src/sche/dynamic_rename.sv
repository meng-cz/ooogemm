// Register renamer for dynamic_uopparse uops.
//
// A/B/ACC uop fields at the input are logical names.  The renamed output
// carries physical names and is accepted in the same cycle as its input.
// LOAD writes a new A or B version.  GEMM with accum=0 overwrites its logical
// ACC name with a newly allocated physical version.  GEMM with accum=1 instead
// reads and writes the current ACC physical item in place: the dynamic issue
// stage must serialize GEMMs for a shared logical ACC name before execution.
// OUTPUT reads and retires the current ACC version.
//
// Read completion feedback is deliberately registered: a *_read_done_i pulse
// only changes the free list after this clock edge, so an entry released by a
// completion cannot be allocated by the current cycle's combinational logic.

`default_nettype none

module dynamic_rename #(
    parameter int ABUF_LOGIC_SIZE = 16,
    parameter int BBUF_LOGIC_SIZE = 16,
    parameter int ACC_LOGIC_SIZE  = 16,
    parameter int ABUF_PHYS_SIZE  = ABUF_LOGIC_SIZE,
    parameter int BBUF_PHYS_SIZE  = BBUF_LOGIC_SIZE,
    parameter int ACC_PHYS_SIZE   = ACC_LOGIC_SIZE,
    parameter int ADDR_WIDTH      = 32,
    parameter int LOAD_ROWS_WIDTH = 6,
    parameter int ABUF_LOGIC_IDX_WIDTH =
        (ABUF_LOGIC_SIZE <= 1) ? 1 : $clog2(ABUF_LOGIC_SIZE),
    parameter int BBUF_LOGIC_IDX_WIDTH =
        (BBUF_LOGIC_SIZE <= 1) ? 1 : $clog2(BBUF_LOGIC_SIZE),
    parameter int ACC_LOGIC_IDX_WIDTH =
        (ACC_LOGIC_SIZE <= 1) ? 1 : $clog2(ACC_LOGIC_SIZE),
    parameter int ABUF_PHYS_IDX_WIDTH =
        (ABUF_PHYS_SIZE <= 1) ? 1 : $clog2(ABUF_PHYS_SIZE),
    parameter int BBUF_PHYS_IDX_WIDTH =
        (BBUF_PHYS_SIZE <= 1) ? 1 : $clog2(BBUF_PHYS_SIZE),
    parameter int ACC_PHYS_IDX_WIDTH =
        (ACC_PHYS_SIZE <= 1) ? 1 : $clog2(ACC_PHYS_SIZE),
    parameter int REFCOUNT_WIDTH = 16
) (
    input  logic clk,
    input  logic rst_n,

    input  logic uop_valid_i,
    output logic uop_ready_o,
    input  uopparse_pkg::uop_type_e uop_type_i,
    input  logic [ADDR_WIDTH-1:0] uop_addr_i,
    input  logic [ABUF_LOGIC_IDX_WIDTH-1:0] uop_abufidx_i,
    input  logic [BBUF_LOGIC_IDX_WIDTH-1:0] uop_bbufidx_i,
    input  logic [ACC_LOGIC_IDX_WIDTH-1:0] uop_paccidx_i,
    input  logic [LOAD_ROWS_WIDTH-1:0] uop_valid_rows_i,
    input  logic uop_accum_i,

    output logic renamed_uop_valid_o,
    input  logic renamed_uop_ready_i,
    output uopparse_pkg::uop_type_e renamed_uop_type_o,
    output logic [ADDR_WIDTH-1:0] renamed_uop_addr_o,
    output logic [ABUF_PHYS_IDX_WIDTH-1:0] renamed_uop_abufidx_o,
    output logic [BBUF_PHYS_IDX_WIDTH-1:0] renamed_uop_bbufidx_o,
    output logic [ACC_PHYS_IDX_WIDTH-1:0] renamed_uop_paccidx_o,
    output logic [LOAD_ROWS_WIDTH-1:0] renamed_uop_valid_rows_o,
    output logic renamed_uop_accum_o,

    // Assert after the consumer has captured an A/B operand, or after it has
    // consumed an ACC version (GEMM accumulate, OUTPUT, or a future GETACC).
    input  logic abuf_read_done_valid_i,
    input  logic [ABUF_PHYS_IDX_WIDTH-1:0] abuf_read_done_phys_i,
    input  logic bbuf_read_done_valid_i,
    input  logic [BBUF_PHYS_IDX_WIDTH-1:0] bbuf_read_done_phys_i,
    input  logic acc_read_done_valid_i,
    input  logic [ACC_PHYS_IDX_WIDTH-1:0] acc_read_done_phys_i
);

    import uopparse_pkg::*;

    typedef logic [REFCOUNT_WIDTH-1:0] refcount_t;

    logic [ABUF_PHYS_IDX_WIDTH-1:0] abuf_map_q [ABUF_LOGIC_SIZE];
    logic [BBUF_PHYS_IDX_WIDTH-1:0] bbuf_map_q [BBUF_LOGIC_SIZE];
    logic [ACC_PHYS_IDX_WIDTH-1:0]  acc_map_q  [ACC_LOGIC_SIZE];
    logic abuf_map_valid_q [ABUF_LOGIC_SIZE];
    logic bbuf_map_valid_q [BBUF_LOGIC_SIZE];
    logic acc_map_valid_q  [ACC_LOGIC_SIZE];
    logic [ABUF_PHYS_SIZE-1:0] abuf_free_q;
    logic [BBUF_PHYS_SIZE-1:0] bbuf_free_q;
    logic [ACC_PHYS_SIZE-1:0]  acc_free_q;
    refcount_t abuf_ref_q [ABUF_PHYS_SIZE];
    refcount_t bbuf_ref_q [BBUF_PHYS_SIZE];
    refcount_t acc_ref_q  [ACC_PHYS_SIZE];

    logic [ABUF_PHYS_IDX_WIDTH-1:0] abuf_map_d [ABUF_LOGIC_SIZE];
    logic [BBUF_PHYS_IDX_WIDTH-1:0] bbuf_map_d [BBUF_LOGIC_SIZE];
    logic [ACC_PHYS_IDX_WIDTH-1:0]  acc_map_d  [ACC_LOGIC_SIZE];
    logic abuf_map_valid_d [ABUF_LOGIC_SIZE];
    logic bbuf_map_valid_d [BBUF_LOGIC_SIZE];
    logic acc_map_valid_d  [ACC_LOGIC_SIZE];
    logic [ABUF_PHYS_SIZE-1:0] abuf_free_d;
    logic [BBUF_PHYS_SIZE-1:0] bbuf_free_d;
    logic [ACC_PHYS_SIZE-1:0]  acc_free_d;
    refcount_t abuf_ref_d [ABUF_PHYS_SIZE];
    refcount_t bbuf_ref_d [BBUF_PHYS_SIZE];
    refcount_t acc_ref_d  [ACC_PHYS_SIZE];

    logic abuf_alloc_found;
    logic bbuf_alloc_found;
    logic acc_alloc_found;
    logic [ABUF_PHYS_IDX_WIDTH-1:0] abuf_alloc_phys;
    logic [BBUF_PHYS_IDX_WIDTH-1:0] bbuf_alloc_phys;
    logic [ACC_PHYS_IDX_WIDTH-1:0]  acc_alloc_phys;
    logic abuf_logic_in_range;
    logic bbuf_logic_in_range;
    logic acc_logic_in_range;
    logic abuf_read_valid;
    logic bbuf_read_valid;
    logic acc_read_valid;
    logic uop_can_rename;
    logic uop_fire;

    always_comb begin
        abuf_alloc_found = 1'b0;
        abuf_alloc_phys = '0;
        for (int p = 0; p < ABUF_PHYS_SIZE; p++) begin
            if (!abuf_alloc_found && abuf_free_q[p]) begin
                abuf_alloc_found = 1'b1;
                abuf_alloc_phys = ABUF_PHYS_IDX_WIDTH'(p);
            end
        end
        bbuf_alloc_found = 1'b0;
        bbuf_alloc_phys = '0;
        for (int p = 0; p < BBUF_PHYS_SIZE; p++) begin
            if (!bbuf_alloc_found && bbuf_free_q[p]) begin
                bbuf_alloc_found = 1'b1;
                bbuf_alloc_phys = BBUF_PHYS_IDX_WIDTH'(p);
            end
        end
        acc_alloc_found = 1'b0;
        acc_alloc_phys = '0;
        for (int p = 0; p < ACC_PHYS_SIZE; p++) begin
            if (!acc_alloc_found && acc_free_q[p]) begin
                acc_alloc_found = 1'b1;
                acc_alloc_phys = ACC_PHYS_IDX_WIDTH'(p);
            end
        end
    end

    always_comb begin
        abuf_logic_in_range = int'(uop_abufidx_i) < ABUF_LOGIC_SIZE;
        bbuf_logic_in_range = int'(uop_bbufidx_i) < BBUF_LOGIC_SIZE;
        acc_logic_in_range = int'(uop_paccidx_i) < ACC_LOGIC_SIZE;
        abuf_read_valid = abuf_logic_in_range && abuf_map_valid_q[int'(uop_abufidx_i)];
        bbuf_read_valid = bbuf_logic_in_range && bbuf_map_valid_q[int'(uop_bbufidx_i)];
        acc_read_valid = acc_logic_in_range && acc_map_valid_q[int'(uop_paccidx_i)];

        uop_can_rename = 1'b1;
        unique case (uop_type_i)
            UOP_LOAD_A: uop_can_rename = abuf_logic_in_range && abuf_alloc_found;
            UOP_LOAD_B: uop_can_rename = bbuf_logic_in_range && bbuf_alloc_found;
            UOP_GEMM: begin
                uop_can_rename = abuf_read_valid && bbuf_read_valid &&
                    acc_logic_in_range &&
                    (uop_accum_i ? acc_read_valid : acc_alloc_found);
            end
            UOP_OUTPUT: uop_can_rename = acc_read_valid;
            default: uop_can_rename = 1'b1;
        endcase
    end

    assign renamed_uop_valid_o = uop_valid_i && uop_can_rename;
    assign uop_ready_o = renamed_uop_ready_i && uop_can_rename;
    assign uop_fire = uop_valid_i && uop_ready_o;

    always_comb begin
        renamed_uop_type_o = uop_type_i;
        renamed_uop_addr_o = uop_addr_i;
        renamed_uop_abufidx_o = '0;
        renamed_uop_bbufidx_o = '0;
        renamed_uop_paccidx_o = '0;
        renamed_uop_valid_rows_o = uop_valid_rows_i;
        renamed_uop_accum_o = uop_accum_i;
        if (uop_can_rename) begin
            unique case (uop_type_i)
                UOP_LOAD_A: renamed_uop_abufidx_o = abuf_alloc_phys;
                UOP_LOAD_B: renamed_uop_bbufidx_o = bbuf_alloc_phys;
                UOP_GEMM: begin
                    renamed_uop_abufidx_o = abuf_map_q[int'(uop_abufidx_i)];
                    renamed_uop_bbufidx_o = bbuf_map_q[int'(uop_bbufidx_i)];
                    renamed_uop_paccidx_o = uop_accum_i ?
                        acc_map_q[int'(uop_paccidx_i)] : acc_alloc_phys;
                end
                UOP_OUTPUT: renamed_uop_paccidx_o = acc_map_q[int'(uop_paccidx_i)];
                default: begin end
            endcase
        end
    end

    always_comb begin
        for (int l = 0; l < ABUF_LOGIC_SIZE; l++) begin
            abuf_map_d[l] = abuf_map_q[l];
            abuf_map_valid_d[l] = abuf_map_valid_q[l];
        end
        for (int l = 0; l < BBUF_LOGIC_SIZE; l++) begin
            bbuf_map_d[l] = bbuf_map_q[l];
            bbuf_map_valid_d[l] = bbuf_map_valid_q[l];
        end
        for (int l = 0; l < ACC_LOGIC_SIZE; l++) begin
            acc_map_d[l] = acc_map_q[l];
            acc_map_valid_d[l] = acc_map_valid_q[l];
        end
        for (int p = 0; p < ABUF_PHYS_SIZE; p++) begin
            abuf_ref_d[p] = abuf_ref_q[p];
        end
        for (int p = 0; p < BBUF_PHYS_SIZE; p++) begin
            bbuf_ref_d[p] = bbuf_ref_q[p];
        end
        for (int p = 0; p < ACC_PHYS_SIZE; p++) begin
            acc_ref_d[p] = acc_ref_q[p];
        end

        // Completion effects become architectural after this edge.  They are
        // intentionally not consulted by uop_can_rename above.
        if (abuf_read_done_valid_i &&
            (int'(abuf_read_done_phys_i) < ABUF_PHYS_SIZE) &&
            (abuf_ref_q[int'(abuf_read_done_phys_i)] != '0)) begin
            abuf_ref_d[int'(abuf_read_done_phys_i)] =
                abuf_ref_q[int'(abuf_read_done_phys_i)] - 1'b1;
        end
        if (bbuf_read_done_valid_i &&
            (int'(bbuf_read_done_phys_i) < BBUF_PHYS_SIZE) &&
            (bbuf_ref_q[int'(bbuf_read_done_phys_i)] != '0)) begin
            bbuf_ref_d[int'(bbuf_read_done_phys_i)] =
                bbuf_ref_q[int'(bbuf_read_done_phys_i)] - 1'b1;
        end
        if (acc_read_done_valid_i &&
            (int'(acc_read_done_phys_i) < ACC_PHYS_SIZE) &&
            (acc_ref_q[int'(acc_read_done_phys_i)] != '0)) begin
            acc_ref_d[int'(acc_read_done_phys_i)] =
                acc_ref_q[int'(acc_read_done_phys_i)] - 1'b1;
        end

        if (uop_fire) begin
            unique case (uop_type_i)
                UOP_LOAD_A: begin
                    abuf_map_d[int'(uop_abufidx_i)] = abuf_alloc_phys;
                    abuf_map_valid_d[int'(uop_abufidx_i)] = 1'b1;
                end
                UOP_LOAD_B: begin
                    bbuf_map_d[int'(uop_bbufidx_i)] = bbuf_alloc_phys;
                    bbuf_map_valid_d[int'(uop_bbufidx_i)] = 1'b1;
                end
                UOP_GEMM: begin
                    abuf_ref_d[int'(abuf_map_q[int'(uop_abufidx_i)])] =
                        abuf_ref_d[int'(abuf_map_q[int'(uop_abufidx_i)])] + 1'b1;
                    bbuf_ref_d[int'(bbuf_map_q[int'(uop_bbufidx_i)])] =
                        bbuf_ref_d[int'(bbuf_map_q[int'(uop_bbufidx_i)])] + 1'b1;
                    if (uop_accum_i) begin
                        // accum=1 is an in-place read-modify-write.  Keep a
                        // read reference until execution reports completion,
                        // but do not allocate or rename the ACC destination.
                        // The issue stage serializes same-pacc GEMMs so that
                        // this physical in-place update observes its predecessor.
                        acc_ref_d[int'(acc_map_q[int'(uop_paccidx_i)])] =
                            acc_ref_d[int'(acc_map_q[int'(uop_paccidx_i)])] + 1'b1;
                    end else begin
                        // accum=0 starts a fresh accumulator version.  The
                        // previous mapping, if any, becomes reclaimable only
                        // after all of its already-bound readers complete.
                        acc_map_d[int'(uop_paccidx_i)] = acc_alloc_phys;
                        acc_map_valid_d[int'(uop_paccidx_i)] = 1'b1;
                    end
                end
                UOP_OUTPUT: begin
                    acc_ref_d[int'(acc_map_q[int'(uop_paccidx_i)])] =
                        acc_ref_d[int'(acc_map_q[int'(uop_paccidx_i)])] + 1'b1;
                    // OUTPUT consumes the architectural ACC version.  The
                    // physical tag remains live through its read reference,
                    // then becomes reclaimable when acc_read_done arrives.
                    acc_map_valid_d[int'(uop_paccidx_i)] = 1'b0;
                end
                default: begin end
            endcase
        end

        // A physical version is free exactly when it has no map entry and no
        // dispatched reader.  Rebuild free lists from this invariant after all
        // feedback and rename updates above.
        for (int p = 0; p < ABUF_PHYS_SIZE; p++) begin
            logic mapped;
            mapped = 1'b0;
            for (int l = 0; l < ABUF_LOGIC_SIZE; l++) begin
                mapped |= abuf_map_valid_d[l] && (int'(abuf_map_d[l]) == p);
            end
            abuf_free_d[p] = !mapped && (abuf_ref_d[p] == '0);
        end
        for (int p = 0; p < BBUF_PHYS_SIZE; p++) begin
            logic mapped;
            mapped = 1'b0;
            for (int l = 0; l < BBUF_LOGIC_SIZE; l++) begin
                mapped |= bbuf_map_valid_d[l] && (int'(bbuf_map_d[l]) == p);
            end
            bbuf_free_d[p] = !mapped && (bbuf_ref_d[p] == '0);
        end
        for (int p = 0; p < ACC_PHYS_SIZE; p++) begin
            logic mapped;
            mapped = 1'b0;
            for (int l = 0; l < ACC_LOGIC_SIZE; l++) begin
                mapped |= acc_map_valid_d[l] && (int'(acc_map_d[l]) == p);
            end
            acc_free_d[p] = !mapped && (acc_ref_d[p] == '0);
        end
    end

    initial begin
        if ((ABUF_LOGIC_SIZE <= 0) || (BBUF_LOGIC_SIZE <= 0) ||
            (ACC_LOGIC_SIZE <= 0) || (ABUF_PHYS_SIZE <= 0) ||
            (BBUF_PHYS_SIZE <= 0) || (ACC_PHYS_SIZE <= 0)) begin
            $error("dynamic_rename resource sizes must be positive");
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int l = 0; l < ABUF_LOGIC_SIZE; l++) begin
                abuf_map_q[l] <= '0;
                abuf_map_valid_q[l] <= 1'b0;
            end
            for (int l = 0; l < BBUF_LOGIC_SIZE; l++) begin
                bbuf_map_q[l] <= '0;
                bbuf_map_valid_q[l] <= 1'b0;
            end
            for (int l = 0; l < ACC_LOGIC_SIZE; l++) begin
                acc_map_q[l] <= '0;
                acc_map_valid_q[l] <= 1'b0;
            end
            for (int p = 0; p < ABUF_PHYS_SIZE; p++) begin
                abuf_ref_q[p] <= '0;
                abuf_free_q[p] <= 1'b1;
            end
            for (int p = 0; p < BBUF_PHYS_SIZE; p++) begin
                bbuf_ref_q[p] <= '0;
                bbuf_free_q[p] <= 1'b1;
            end
            for (int p = 0; p < ACC_PHYS_SIZE; p++) begin
                acc_ref_q[p] <= '0;
                acc_free_q[p] <= 1'b1;
            end
        end else begin
            for (int l = 0; l < ABUF_LOGIC_SIZE; l++) begin
                abuf_map_q[l] <= abuf_map_d[l];
                abuf_map_valid_q[l] <= abuf_map_valid_d[l];
            end
            for (int l = 0; l < BBUF_LOGIC_SIZE; l++) begin
                bbuf_map_q[l] <= bbuf_map_d[l];
                bbuf_map_valid_q[l] <= bbuf_map_valid_d[l];
            end
            for (int l = 0; l < ACC_LOGIC_SIZE; l++) begin
                acc_map_q[l] <= acc_map_d[l];
                acc_map_valid_q[l] <= acc_map_valid_d[l];
            end
            for (int p = 0; p < ABUF_PHYS_SIZE; p++) begin
                abuf_ref_q[p] <= abuf_ref_d[p];
                abuf_free_q[p] <= abuf_free_d[p];
            end
            for (int p = 0; p < BBUF_PHYS_SIZE; p++) begin
                bbuf_ref_q[p] <= bbuf_ref_d[p];
                bbuf_free_q[p] <= bbuf_free_d[p];
            end
            for (int p = 0; p < ACC_PHYS_SIZE; p++) begin
                acc_ref_q[p] <= acc_ref_d[p];
                acc_free_q[p] <= acc_free_d[p];
            end
        end
    end

endmodule

`default_nettype wire
